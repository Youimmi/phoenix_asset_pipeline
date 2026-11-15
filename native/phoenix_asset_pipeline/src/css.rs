use crate::binary::BinaryBuilder;
use ahash::{AHashMap, AHashSet, RandomState};
use core::fmt::NumBuffer;
use cssparser::{ParseError, ParseErrorKind, Parser, SourcePosition, Token};
use lightningcss::{
    declaration::DeclarationBlock,
    printer::{Printer, PrinterOptions},
    properties::{Property, PropertyId},
    rules::{CssRule, CssRuleList, supports::SupportsCondition},
    selector::{Component, PseudoClass, PseudoElement, Selector},
    stylesheet::{MinifyOptions, ParserOptions, StyleSheet},
    values::{ident::Ident, string::CSSString},
    vendor_prefix::VendorPrefix,
    visitor::{Visit, VisitTypes, Visitor},
};
use parcel_selectors::{
    attr::{AttrSelectorOperator, ParsedAttrSelectorOperation, ParsedCaseSensitivity},
    parser::NthOfSelectorData,
};
use rustler::{Binary, Encoder, Env, Term};

const CLASS_MARKER_BASE: &str = "__p";
// Lightning CSS recurses through nested rules and long expressions, so preparation runs on its own
// stack instead of the small dirty scheduler stack. The stack is reserved lazily.
const CSS_STACK_SIZE: usize = 256 * 1024 * 1024;
const MAX_CSS_NESTING: usize = 128;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[derive(Debug, Default)]
struct CustomPropertyContext {
    parenthesis_depth: usize,
    property_references: bool,
    style_depth: usize,
    style_value_depth: usize,
}

impl CustomPropertyContext {
    fn update(&mut self, bytes: &[u8], index: usize) {
        match bytes[index] {
            b'(' => {
                self.parenthesis_depth += 1;
                if self.style_depth == 0 && css_function_name(bytes, index, b"style") {
                    self.style_depth = self.parenthesis_depth;
                }
            }
            b')' => {
                if self.style_value_depth == self.parenthesis_depth {
                    self.style_value_depth = 0;
                }
                if self.style_depth == self.parenthesis_depth {
                    self.style_depth = 0;
                }
                self.parenthesis_depth = self.parenthesis_depth.saturating_sub(1);
            }
            b':' => {
                let property = declared_property(bytes, index);
                self.property_references = matches!(
                    property,
                    b"transition" | b"transition-property" | b"will-change"
                );
                if self.style_depth != 0 && self.style_value_depth == 0 {
                    self.style_value_depth = self.parenthesis_depth;
                }
            }
            b';' | b'{' | b'}' => {
                self.property_references = false;
            }
            _ => {}
        }
    }
}

#[derive(Debug)]
struct PreparedCss {
    class_counts: Vec<usize>,
    code: String,
    custom_property_counts: Vec<(String, usize, bool)>,
    marker_classes: Vec<String>,
    marker_prefix: String,
}

struct SelectorClassProcessor {
    class_indices: AHashMap<String, (usize, usize, Ident<'static>)>,
    marker_prefix: String,
}

impl SelectorClassProcessor {
    fn class_marker(&mut self, class_name: &str) -> Ident<'static> {
        match self.class_indices.get_mut(class_name) {
            Some((_, count, marker)) => {
                *count += 1;
                marker.clone()
            }
            None => {
                let index = self.class_indices.len();
                let mut buffer = NumBuffer::new();
                let index_text = index.format_into(&mut buffer);
                let mut marker =
                    String::with_capacity(self.marker_prefix.len() + index_text.len() + 1);
                marker.push_str(&self.marker_prefix);
                marker.push_str(index_text);
                marker.push('_');

                let marker = Ident(marker.into());
                self.class_indices
                    .insert(class_name.to_owned(), (index, 1, marker.clone()));
                marker
            }
        }
    }

    fn mark_supports_attribute_value(
        &mut self,
        parser: &mut Parser<'_>,
        output: &mut String,
        operator: AttrSelectorOperator,
    ) -> Result<(), ParseError<String>> {
        let start = parser.position();
        parser.skip_whitespace();
        let value_start = parser.position();
        let value = parser.expect_ident_or_string()?.clone();
        let text = parser.slice_from(value_start);
        let value_end = parser.position();
        let case_sensitivity = match parser.try_parse(Parser::expect_ident_cloned) {
            Ok(flag) if flag.eq_ignore_ascii_case("i") => {
                ParsedCaseSensitivity::AsciiCaseInsensitive
            }
            Ok(flag) if flag.eq_ignore_ascii_case("s") => {
                ParsedCaseSensitivity::ExplicitCaseSensitive
            }
            _ => ParsedCaseSensitivity::CaseSensitive,
        };
        let mut value = CSSString(value.as_ref().into());
        self.process_attribute_classes(operator, case_sensitivity, &mut value)
            .map_err(ParseError::custom)?;

        output.push_str(parser.slice(start..value_start));
        if let Some(&quote @ (b'\'' | b'"')) = text.as_bytes().first() {
            output.push(char::from(quote));
            output.push_str(value.0.as_ref());
            if text.len() > 1 && text.as_bytes().last() == Some(&quote) {
                output.push(char::from(quote));
            }
        } else {
            output.push_str(value.0.as_ref());
        }
        output.push_str(parser.slice_from(value_end));
        Ok(())
    }

    // Copies the tokens of an `@supports selector()` argument as written and marks its classes.
    // Returns where the enclosing block ends, so its closing bracket is copied as written too.
    fn mark_supports_selector(
        &mut self,
        parser: &mut Parser<'_>,
        output: &mut String,
        depth: usize,
        attribute: bool,
    ) -> Result<SourcePosition, ParseError<String>> {
        if depth > MAX_CSS_NESTING {
            return Err(ParseError::custom(format!(
                "CSS selector nesting exceeds the limit of {MAX_CSS_NESTING}"
            )));
        }

        let mut class = false;
        let mut class_attribute = false;
        let mut attribute_name = attribute;
        let mut namespaced = false;

        loop {
            let start = parser.position();
            let Ok(token) = parser.next_including_whitespace_and_comments().cloned() else {
                return Ok(start);
            };
            let text = parser.slice_from(start);

            match &token {
                Token::Ident(name) if class && !attribute => {
                    output.push_str(self.class_marker(name).0.as_ref());
                }
                Token::Function(_)
                | Token::ParenthesisBlock
                | Token::SquareBracketBlock
                | Token::CurlyBracketBlock => {
                    output.push_str(text);

                    let attribute = token == Token::SquareBracketBlock;
                    let end = parser.parse_nested_block(|parser| {
                        self.mark_supports_selector(parser, output, depth + 1, attribute)
                    })?;

                    output.push_str(parser.slice_from(end));
                }
                Token::Delim('=')
                | Token::IncludeMatch
                | Token::DashMatch
                | Token::PrefixMatch
                | Token::SuffixMatch
                | Token::SubstringMatch
                    if class_attribute =>
                {
                    if namespaced {
                        return Err(ParseError::custom(
                            "namespaced CSS class attribute selectors cannot be obfuscated",
                        ));
                    }
                    let operator = match token {
                        Token::Delim('=') => AttrSelectorOperator::Equal,
                        Token::IncludeMatch => AttrSelectorOperator::Includes,
                        Token::DashMatch => AttrSelectorOperator::DashMatch,
                        Token::PrefixMatch => AttrSelectorOperator::Prefix,
                        Token::SuffixMatch => AttrSelectorOperator::Suffix,
                        Token::SubstringMatch => AttrSelectorOperator::Substring,
                        _ => unreachable!(),
                    };
                    output.push_str(text);
                    self.mark_supports_attribute_value(parser, output, operator)?;
                    class_attribute = false;
                }
                Token::Ident(name) if attribute_name => {
                    class_attribute = name.eq_ignore_ascii_case("class");
                    attribute_name = false;
                    output.push_str(text);
                }
                Token::Delim('|') if attribute => {
                    attribute_name = true;
                    namespaced = true;
                    output.push_str(text);
                }
                _ => output.push_str(text),
            }

            if !matches!(token, Token::Comment(_)) {
                class = token == Token::Delim('.');
            }
        }
    }

    fn marker() -> Self {
        Self {
            class_indices: AHashMap::new(),
            marker_prefix: class_marker_prefix(),
        }
    }

    fn process_attribute_classes(
        &mut self,
        operator: AttrSelectorOperator,
        case_sensitivity: ParsedCaseSensitivity,
        value: &mut CSSString<'_>,
    ) -> Result<(), String> {
        let text = value.0.as_ref();

        if !matches!(
            operator,
            AttrSelectorOperator::Equal | AttrSelectorOperator::Includes
        ) {
            return Err("CSS class attribute selectors require '=' or '~=' matching".to_owned());
        }

        if text.is_empty() {
            return Ok(());
        }

        if text.bytes().any(css_whitespace) {
            return Err(
                "CSS class equality selectors require an empty value or one token without whitespace"
                    .to_owned(),
            );
        }

        if !matches!(
            case_sensitivity,
            ParsedCaseSensitivity::CaseSensitive | ParsedCaseSensitivity::ExplicitCaseSensitive
        ) {
            return Err("CSS class attribute selectors require case-sensitive matching".to_owned());
        }

        *value = CSSString(self.class_marker(text).0);
        Ok(())
    }

    fn process_class(&mut self, class: &mut Ident<'_>) {
        let marker = self.class_marker(class.0.as_ref());

        *class = marker;
    }

    fn process_component(
        &mut self,
        component: &mut Component<'_>,
        depth: usize,
    ) -> Result<(), String> {
        match component {
            Component::AttributeInNoNamespace {
                local_name,
                operator,
                value,
                case_sensitivity,
                never_matches: false,
            } if local_name.0.as_ref() == "class" => {
                self.process_attribute_classes(*operator, *case_sensitivity, value)?;
            }
            Component::AttributeOther(attribute)
                if attribute.local_name_lower.0.as_ref() == "class" && !attribute.never_matches =>
            {
                if let ParsedAttrSelectorOperation::WithValue {
                    operator,
                    case_sensitivity,
                    expected_value,
                } = &mut attribute.operation
                {
                    if attribute.namespace.is_some() && !expected_value.bytes().all(css_whitespace)
                    {
                        return Err(
                            "namespaced CSS class attribute selectors cannot be obfuscated"
                                .to_owned(),
                        );
                    }
                    self.process_attribute_classes(*operator, *case_sensitivity, expected_value)?;
                }
            }
            Component::Class(class) => self.process_class(class),
            Component::Negation(selectors)
            | Component::Where(selectors)
            | Component::Is(selectors)
            | Component::Any(_, selectors)
            | Component::Has(selectors) => self.process_selectors(selectors, depth)?,
            Component::Slotted(selector) => self.process_selector(selector, depth + 1)?,
            Component::Host(Some(selector)) => self.process_selector(selector, depth + 1)?,
            Component::NthOf(nth) => {
                let nth_data = *nth.nth_data();
                let mut selectors = nth.clone_selectors();
                self.process_selectors(&mut selectors, depth)?;
                *nth = NthOfSelectorData::new(nth_data, selectors);
            }
            Component::NonTSPseudoClass(
                PseudoClass::Local { selector } | PseudoClass::Global { selector },
            ) => self.process_selector(selector, depth + 1)?,
            Component::PseudoElement(
                PseudoElement::CueFunction { selector }
                | PseudoElement::CueRegionFunction { selector },
            ) => self.process_selector(selector, depth + 1)?,
            _ => {}
        }

        Ok(())
    }
    fn process_selector(
        &mut self,
        selector: &mut Selector<'_>,
        depth: usize,
    ) -> Result<(), String> {
        if depth > MAX_CSS_NESTING {
            return Err(format!(
                "CSS selector nesting exceeds the limit of {MAX_CSS_NESTING}"
            ));
        }

        for component in selector.iter_mut_raw_match_order() {
            self.process_component(component, depth)?;
        }

        Ok(())
    }

    fn process_selectors(
        &mut self,
        selectors: &mut [Selector<'_>],
        depth: usize,
    ) -> Result<(), String> {
        for selector in selectors {
            self.process_selector(selector, depth + 1)?;
        }

        Ok(())
    }
}

impl<'i> Visitor<'i> for SelectorClassProcessor {
    type Error = String;

    fn visit_selector(&mut self, selector: &mut Selector<'i>) -> Result<(), Self::Error> {
        self.process_selector(selector, 0)
    }

    // The condition tests the selector's syntax, so it is rewritten token by token: reprinting the
    // parsed selector would drop what the forgiving parser could not read and change the answer.
    fn visit_supports_condition(
        &mut self,
        condition: &mut SupportsCondition<'i>,
    ) -> Result<(), Self::Error> {
        if let SupportsCondition::Selector(raw_selector) = condition {
            let mut output = String::with_capacity(raw_selector.len());

            self.mark_supports_selector(
                &mut Parser::new(raw_selector.as_ref()),
                &mut output,
                0,
                false,
            )
            .map_err(|error| match error.kind {
                ParseErrorKind::Custom(reason) => reason,
                kind => format!("could not read @supports selector(): {kind:?}"),
            })?;

            *raw_selector = output.into();

            Ok(())
        } else {
            condition.visit_children(self)
        }
    }

    fn visit_types(&self) -> VisitTypes {
        VisitTypes::SELECTORS | VisitTypes::SUPPORTS_CONDITIONS
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn finalize_css_nif<'a>(
    env: Env<'a>,
    css: Binary<'a>,
    marker_prefix: Binary<'a>,
    class_replacements: Vec<Binary<'a>>,
    variable_replacements: Vec<(Binary<'a>, Binary<'a>)>,
) -> Term<'a> {
    encode_result(
        env,
        finalize_css(
            env,
            css,
            marker_prefix.as_slice(),
            &class_replacements,
            &variable_replacements,
        ),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn prepare_css_nif<'a>(env: Env<'a>, raw_css: Binary<'a>) -> Term<'a> {
    encode_result(
        env,
        css_text(raw_css)
            .and_then(prepare_css_on_css_stack)
            .map(|prepared| {
                (
                    prepared.code,
                    prepared.marker_classes,
                    prepared.class_counts,
                    prepared.marker_prefix,
                    prepared.custom_property_counts,
                )
            }),
    )
}

fn class_marker_prefix() -> String {
    let state = RandomState::new();
    let first = state.hash_one(0_u8);
    let second = state.hash_one(1_u8);

    format!("{CLASS_MARKER_BASE}{first:016x}{second:016x}_")
}

// Counts each custom property and whether this stylesheet declares it.
fn collect_custom_properties(css: &str) -> Vec<(String, usize, bool)> {
    let bytes = css.as_bytes();
    let mut counts = AHashMap::new();
    let mut declared = AHashSet::new();
    let mut cursor = 0;
    let mut context = CustomPropertyContext::default();

    while cursor < bytes.len() {
        if let Some(stop) = skip_css_literal(bytes, cursor) {
            cursor = stop;
        } else if bytes[cursor] == b'-'
            && let Some(stop) = custom_property_end(bytes, cursor)
        {
            let property = &css[cursor..stop];

            if custom_property_context(bytes, cursor, stop, &context) {
                if custom_property_declared(bytes, cursor, stop) {
                    declared.insert(property);
                }

                counts
                    .entry(property)
                    .and_modify(|count| {
                        if *count != 0 {
                            *count += 1;
                        }
                    })
                    .or_insert(1);
            } else {
                // Zero reserves names used as opaque values, including aliases and anchor names.
                counts.insert(property, 0);
            }

            cursor = stop;
        } else {
            context.update(bytes, cursor);
            cursor += 1;
        }
    }

    let mut counts = counts
        .into_iter()
        .map(|(property, count)| (property.to_owned(), count, declared.contains(property)))
        .collect::<Vec<_>>();
    counts.sort_unstable_by(|left, right| left.0.cmp(&right.0));
    counts
}

fn css_function_name(bytes: &[u8], open: usize, name: &[u8]) -> bool {
    open >= name.len()
        && bytes[open - name.len()..open].eq_ignore_ascii_case(name)
        && (open == name.len() || !css_variable_byte(bytes[open - name.len() - 1]))
}

fn css_text(css: Binary<'_>) -> Result<&str, String> {
    std::str::from_utf8(css.as_slice()).map_err(|error| format!("CSS is not valid UTF-8: {error}"))
}

fn css_url_start(bytes: &[u8], index: usize) -> bool {
    bytes[index..]
        .get(..4)
        .is_some_and(|name| name.eq_ignore_ascii_case(b"url("))
        && (index == 0 || !css_variable_byte(bytes[index - 1]))
}

fn css_variable_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | 0x80..=0xff)
}

fn css_whitespace(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | 0x0c)
}

fn custom_property_context(
    bytes: &[u8],
    index: usize,
    stop: usize,
    context: &CustomPropertyContext,
) -> bool {
    let next = skip_css_whitespace(bytes, stop);
    let previous = previous_non_whitespace(bytes, index);

    // `style()` and `@supports` conditions name a property without declaring it.
    let condition =
        bytes.get(next) == Some(&b':') && previous.is_some_and(|open| bytes[open] == b'(');

    let function_reference = matches!(bytes.get(next), Some(b',' | b')'))
        && previous.is_some_and(|open| {
            bytes[open] == b'('
                && ([b"var".as_slice(), b"style".as_slice()]
                    .iter()
                    .any(|name| css_function_name(bytes, open, name))
                    || (context.style_depth != 0
                        && context.style_value_depth == 0
                        && bytes.get(next) == Some(&b')')
                        && (open == 0 || !css_variable_byte(bytes[open - 1]))))
        });

    condition
        || function_reference
        || custom_property_declared(bytes, index, stop)
        || (context.property_references && listed_property(bytes, index, stop))
}

// Whether a declaration or an `@property` rule defines the property here.
fn custom_property_declared(bytes: &[u8], index: usize, stop: usize) -> bool {
    let previous = previous_non_whitespace(bytes, index);

    match bytes.get(skip_css_whitespace(bytes, stop)) {
        Some(b':') => previous.is_none_or(|previous| matches!(bytes[previous], b'{' | b';')),
        Some(b'{') => previous.is_some_and(|end| {
            end >= 8
                && bytes[end - 8..=end].eq_ignore_ascii_case(b"@property")
                && (end == 8 || !css_variable_byte(bytes[end - 9]))
        }),
        _ => false,
    }
}

fn custom_property_end(bytes: &[u8], index: usize) -> Option<usize> {
    if index + 2 >= bytes.len()
        || bytes[index + 1] != b'-'
        || !css_variable_byte(bytes[index + 2])
        || (index > 0 && (css_variable_byte(bytes[index - 1]) || bytes[index - 1] == b'\\'))
    {
        return None;
    }

    let mut stop = index + 3;

    while stop < bytes.len() && css_variable_byte(bytes[stop]) {
        stop += 1;
    }

    Some(stop)
}

// The property a declaration colon belongs to, or nothing when the colon is not a declaration's.
fn declared_property(bytes: &[u8], colon: usize) -> &[u8] {
    let Some(end) = previous_non_whitespace(bytes, colon) else {
        return &[];
    };
    let mut start = end + 1;

    while start > 0 && css_variable_byte(bytes[start - 1]) {
        start -= 1;
    }

    if previous_non_whitespace(bytes, start)
        .is_some_and(|previous| matches!(bytes[previous], b'{' | b';' | b'('))
    {
        &bytes[start..=end]
    } else {
        &[]
    }
}

fn encode_result<'a, T: Encoder>(env: Env<'a>, result: Result<T, String>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

fn finalize_css<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    marker_prefix: &[u8],
    class_replacements: &[Binary<'_>],
    variable_replacements: &[(Binary<'_>, Binary<'_>)],
) -> Result<Binary<'a>, String> {
    let css = css_text(input)?;

    for (index, replacement) in class_replacements.iter().enumerate() {
        let replacement = std::str::from_utf8(replacement.as_slice())
            .map_err(|error| format!("class replacement is not valid UTF-8: {error}"))?;

        if !replacement.starts_with('.') {
            return Err(format!("invalid replacement for CSS class marker {index}"));
        }
    }

    let mut variables = AHashMap::with_capacity(variable_replacements.len());

    for (variable, replacement) in variable_replacements {
        let variable = std::str::from_utf8(variable.as_slice())
            .map_err(|error| format!("CSS variable is not valid UTF-8: {error}"))?;
        let replacement = std::str::from_utf8(replacement.as_slice())
            .map_err(|error| format!("CSS variable replacement is not valid UTF-8: {error}"))?;
        variables.insert(variable.as_bytes(), replacement.as_bytes());
    }

    let bytes = css.as_bytes();
    let mut cursor = 0;
    let mut last = 0;
    let mut string_quote = None;
    let mut output = None;
    let mut context = CustomPropertyContext::default();

    while cursor < bytes.len() {
        if let Some(quote) = string_quote {
            if bytes[cursor] == b'\\' {
                cursor = (cursor + 2).min(bytes.len());
                continue;
            }
            if bytes[cursor] == quote {
                string_quote = None;
                cursor += 1;
                continue;
            }
        } else if matches!(bytes[cursor], b'\'' | b'"') {
            if class_replacements.is_empty() {
                cursor = skip_css_string(bytes, cursor);
            } else {
                string_quote = Some(bytes[cursor]);
                cursor += 1;
            }
            continue;
        } else if let Some(stop) = skip_css_literal(bytes, cursor) {
            cursor = stop;
            continue;
        }

        let dotted_class = bytes[cursor] == b'.';
        let marker_start = cursor + usize::from(dotted_class);

        if !class_replacements.is_empty() && bytes[marker_start..].starts_with(marker_prefix) {
            let mut index_cursor = marker_start + marker_prefix.len();
            let index_start = index_cursor;
            let mut index = 0_usize;

            while let Some(byte @ b'0'..=b'9') = bytes.get(index_cursor).copied() {
                index = index
                    .checked_mul(10)
                    .and_then(|index| index.checked_add(usize::from(byte - b'0')))
                    .ok_or_else(|| "CSS class marker index is too large".to_owned())?;
                index_cursor += 1;
            }

            if index_cursor == index_start || bytes.get(index_cursor) != Some(&b'_') {
                return Err(format!("invalid CSS class marker at byte {cursor}"));
            }

            let replacement = class_replacements
                .get(index)
                .ok_or_else(|| format!("missing replacement for CSS class marker {index}"))?;
            let output = output.get_or_insert_with(|| BinaryBuilder::new(bytes.len(), usize::MAX));

            if !output.push(&bytes[last..cursor])
                || !output.push(&replacement.as_slice()[usize::from(!dotted_class)..])
            {
                return Err("CSS output is too large".to_owned());
            }

            cursor = index_cursor + 1;
            last = cursor;
            continue;
        }

        if string_quote.is_some() {
            cursor += 1;
            continue;
        }

        if !variables.is_empty()
            && bytes[cursor] == b'-'
            && let Some(stop) = custom_property_end(bytes, cursor)
        {
            if custom_property_context(bytes, cursor, stop, &context)
                && let Some(replacement) = variables.get(&bytes[cursor..stop])
            {
                let output =
                    output.get_or_insert_with(|| BinaryBuilder::new(bytes.len(), usize::MAX));

                if !output.push(&bytes[last..cursor]) || !output.push(replacement) {
                    return Err("CSS output is too large".to_owned());
                }

                last = stop;
            }

            cursor = stop;
        } else {
            if !variables.is_empty() {
                context.update(bytes, cursor);
            }
            cursor += 1;
        }
    }

    match output {
        Some(mut output) => {
            if output.push(&bytes[last..]) {
                Ok(output.finish(env))
            } else {
                Err("CSS output is too large".to_owned())
            }
        }
        None => Ok(input),
    }
}

// A dashed identifier standing as an item of a declaration value.
fn listed_property(bytes: &[u8], index: usize, stop: usize) -> bool {
    index > 0
        && (css_whitespace(bytes[index - 1]) || matches!(bytes[index - 1], b':' | b','))
        && bytes.get(stop).is_none_or(|&byte| {
            css_whitespace(byte) || matches!(byte, b',' | b';' | b'}' | b')' | b'!')
        })
}

fn matches_custom_property(property_id: &PropertyId<'_>, name: &str) -> bool {
    matches!(property_id, PropertyId::Custom(property) if property.as_ref() == name)
}

fn minified<'a>() -> PrinterOptions<'a> {
    PrinterOptions {
        minify: true,
        ..PrinterOptions::default()
    }
}

fn modern_supports(condition: &SupportsCondition) -> bool {
    match condition {
        SupportsCondition::And(conditions) => conditions.iter().all(modern_supports),
        SupportsCondition::Declaration { property_id, value } => {
            property_id == &PropertyId::Color && valid_color_function(value.as_ref(), b"color-mix(")
        }
        SupportsCondition::Or(conditions) => supports_pair(
            conditions,
            |property_id, value| {
                matches_custom_property(property_id, "contain-intrinsic-size") && value == "1px"
            },
            |property_id, value| {
                matches!(property_id, PropertyId::Appearance(prefix) if prefix.contains(VendorPrefix::WebKit))
                    && value == "-apple-pay-button"
            },
        ),
        _ => false,
    }
}

// Rule lists nested in a rule, except `@supports`, which callers handle themselves.
fn nested_rules<'a, 'i>(rule: &'a mut CssRule<'i>) -> Option<&'a mut CssRuleList<'i>> {
    match rule {
        CssRule::Container(rule) => Some(&mut rule.rules),
        CssRule::LayerBlock(rule) => Some(&mut rule.rules),
        CssRule::Media(rule) => Some(&mut rule.rules),
        CssRule::Scope(rule) => Some(&mut rule.rules),
        CssRule::StartingStyle(rule) => Some(&mut rule.rules),
        CssRule::Style(rule) => Some(&mut rule.rules),
        _ => None,
    }
}

fn prepare_css(raw_css: &str) -> Result<PreparedCss, String> {
    let mut stylesheet = transformed_stylesheet(raw_css)?;
    let mut processor = SelectorClassProcessor::marker();

    stylesheet
        .visit(&mut processor)
        .map_err(|error| format!("could not prepare CSS selectors: {error}"))?;

    let code = print_stylesheet(&mut stylesheet)?;
    let custom_property_counts = collect_custom_properties(&code);
    let marker_prefix = processor.marker_prefix;
    let mut marker_classes = vec![String::new(); processor.class_indices.len()];
    let mut class_counts = vec![0; processor.class_indices.len()];

    for (class_name, (index, count, _)) in processor.class_indices {
        marker_classes[index] = class_name;
        class_counts[index] = count;
    }

    Ok(PreparedCss {
        class_counts,
        code,
        custom_property_counts,
        marker_classes,
        marker_prefix,
    })
}

fn prepare_css_on_css_stack(raw_css: &str) -> Result<PreparedCss, String> {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("phoenix_asset_pipeline_css".to_owned())
            .stack_size(CSS_STACK_SIZE)
            .spawn_scoped(scope, || prepare_css(raw_css))
            .map_err(|error| format!("could not start CSS preparation: {error}"))?
            .join()
            .map_err(|_| "CSS preparation panicked".to_owned())?
    })
}

fn previous_non_whitespace(bytes: &[u8], index: usize) -> Option<usize> {
    let mut cursor = index;

    while cursor > 0 {
        cursor -= 1;

        if !css_whitespace(bytes[cursor]) {
            return Some(cursor);
        }
    }

    None
}

fn print_stylesheet(stylesheet: &mut StyleSheet<'_>) -> Result<String, String> {
    stylesheet
        .to_css(minified())
        .map(|output| output.code)
        .map_err(|error| format!("could not print CSS: {error}"))
}

fn property_condition(
    condition: &SupportsCondition,
    predicate: impl Fn(&PropertyId, &str) -> bool,
) -> bool {
    match condition {
        SupportsCondition::Declaration { property_id, value } => {
            predicate(property_id, value.as_ref())
        }
        _ => false,
    }
}

fn property_uses_color_mix(property: &Property<'_>, value: &mut String) -> bool {
    value.clear();

    let result = property.value_to_css(&mut Printer::new(value, minified()));

    result.is_ok() && value.contains("color-mix(")
}

fn remove_fallback_declarations(declarations: &mut Vec<Property<'_>>) {
    if declarations.len() < 2 {
        return;
    }

    if declarations.len() == 2 && declarations[0].property_id() != declarations[1].property_id() {
        return;
    }

    let mut property_counts = AHashMap::with_capacity(declarations.len());

    for declaration in declarations.iter() {
        *property_counts
            .entry(declaration.property_id())
            .or_insert(0) += 1;
    }

    if property_counts.len() == declarations.len() {
        return;
    }

    let mut value = String::new();

    declarations.retain(|declaration| {
        let property_id = declaration.property_id();
        let count = property_counts.get_mut(&property_id).unwrap();

        if *count == 0 {
            false
        } else {
            if *count > 1 && property_uses_color_mix(declaration, &mut value) {
                *count = 0;
            }

            true
        }
    });
}

fn remove_fallbacks_from_declaration_block(declarations: &mut DeclarationBlock<'_>) {
    declarations.declarations.reverse();
    remove_fallback_declarations(&mut declarations.declarations);
    declarations.declarations.reverse();

    declarations.important_declarations.reverse();
    remove_fallback_declarations(&mut declarations.important_declarations);
    declarations.important_declarations.reverse();
}

fn remove_modern_fallbacks(rules: &mut CssRuleList<'_>) {
    for rule in &mut rules.0 {
        if let CssRule::Style(style) = rule {
            remove_fallbacks_from_declaration_block(&mut style.declarations);
        }

        if let Some(rules) = nested_rules(rule) {
            remove_modern_fallbacks(rules);
        }
    }
}

fn skip_css_literal(bytes: &[u8], index: usize) -> Option<usize> {
    if bytes[index] == b'/' && bytes.get(index + 1) == Some(&b'*') {
        let mut cursor = index + 2;

        while cursor < bytes.len() {
            if bytes[cursor] == b'*' && bytes.get(cursor + 1) == Some(&b'/') {
                return Some(cursor + 2);
            }
            cursor += 1;
        }

        return Some(cursor);
    }

    if matches!(bytes[index], b'\'' | b'"') {
        return Some(skip_css_string(bytes, index));
    }

    if !css_url_start(bytes, index) {
        return None;
    }

    let mut cursor = index + 4;

    while cursor < bytes.len() {
        match bytes[cursor] {
            b'\\' => cursor = (cursor + 2).min(bytes.len()),
            b'\'' | b'"' => cursor = skip_css_string(bytes, cursor),
            b')' => return Some(cursor + 1),
            _ => cursor += 1,
        }
    }

    Some(cursor)
}

fn skip_css_string(bytes: &[u8], mut index: usize) -> usize {
    let quote = bytes[index];
    index += 1;

    while index < bytes.len() {
        match bytes[index] {
            b'\\' => index = (index + 2).min(bytes.len()),
            byte if byte == quote => return index + 1,
            _ => index += 1,
        }
    }

    index
}

fn skip_css_whitespace(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() && css_whitespace(bytes[index]) {
        index += 1;
    }

    index
}

// True when one condition satisfies `supported` and another is a negation satisfying `unsupported`.
fn supports_pair(
    conditions: &[SupportsCondition],
    supported: impl Fn(&PropertyId, &str) -> bool,
    unsupported: impl Fn(&PropertyId, &str) -> bool,
) -> bool {
    conditions
        .iter()
        .any(|condition| property_condition(condition, &supported))
        && conditions.iter().any(|condition| {
            matches!(condition, SupportsCondition::Not(condition) if property_condition(condition, &unsupported))
        })
}

fn tailwind_legacy_property_condition(condition: &SupportsCondition<'_>) -> bool {
    match condition {
        SupportsCondition::Or(conditions) if conditions.len() == 2 => {
            (tailwind_moz_legacy_property_condition(&conditions[0])
                && tailwind_webkit_legacy_property_condition(&conditions[1]))
                || (tailwind_webkit_legacy_property_condition(&conditions[0])
                    && tailwind_moz_legacy_property_condition(&conditions[1]))
        }
        _ => false,
    }
}

fn tailwind_moz_legacy_property_condition(condition: &SupportsCondition<'_>) -> bool {
    matches!(condition, SupportsCondition::And(conditions) if conditions.len() == 2
    && supports_pair(
        conditions,
        |property_id, value| {
            matches_custom_property(property_id, "-moz-orient") && value == "inline"
        },
        |property_id, value| {
            property_id == &PropertyId::Color
                && valid_color_function(value, b"rgb(from red r g b")
        },
    ))
}

fn tailwind_webkit_legacy_property_condition(condition: &SupportsCondition<'_>) -> bool {
    matches!(condition, SupportsCondition::And(conditions) if conditions.len() == 2
    && supports_pair(
        conditions,
        |property_id, value| {
            matches!(property_id, PropertyId::Hyphens(prefix) if prefix.contains(VendorPrefix::WebKit))
                && value == "none"
        },
        |property_id, value| {
            matches_custom_property(property_id, "margin-trim") && value == "inline"
        },
    ))
}

fn transformed_stylesheet<'i>(raw_css: &'i str) -> Result<StyleSheet<'i>, String> {
    validate_css_structure(raw_css)?;

    let mut stylesheet = StyleSheet::parse(raw_css, ParserOptions::default())
        .map_err(|error| format!("could not parse CSS: {error}"))?;

    unwrap_modern_supports(&mut stylesheet.rules);
    stylesheet
        .minify(MinifyOptions::default())
        .map_err(|error| format!("could not minify CSS: {error}"))?;
    remove_modern_fallbacks(&mut stylesheet.rules);

    Ok(stylesheet)
}

fn unwrap_modern_supports(rules: &mut CssRuleList<'_>) {
    let mut next = Vec::with_capacity(rules.0.len());

    for mut rule in rules.0.drain(..) {
        if let CssRule::Supports(supports) = &mut rule {
            unwrap_modern_supports(&mut supports.rules);

            if tailwind_legacy_property_condition(&supports.condition) {
                continue;
            }

            if modern_supports(&supports.condition) {
                next.append(&mut supports.rules.0);
                continue;
            }
        } else if let Some(rules) = nested_rules(&mut rule) {
            unwrap_modern_supports(rules);
        }

        next.push(rule);
    }

    rules.0 = next;
}

fn valid_color_function(value: &str, prefix: &[u8]) -> bool {
    let value = value.trim_ascii();

    value
        .as_bytes()
        .get(..prefix.len())
        .is_some_and(|name| name.eq_ignore_ascii_case(prefix))
        && matches!(
            Property::parse_string(PropertyId::Color, value, ParserOptions::default()),
            Ok(Property::Color(_))
        )
}

fn validate_css_structure(css: &str) -> Result<(), String> {
    #[derive(Clone, Copy)]
    enum State {
        Normal,
        Comment,
        String(u8, bool),
        Url,
    }

    let bytes = css.as_bytes();
    let mut stack = Vec::with_capacity(16);
    let mut state = State::Normal;
    let mut index = 0;

    while index < bytes.len() {
        match state {
            State::Normal => match bytes[index] {
                b'/' if bytes.get(index + 1) == Some(&b'*') => {
                    state = State::Comment;
                    index += 2;
                }
                quote @ (b'\'' | b'"') => {
                    state = State::String(quote, false);
                    index += 1;
                }
                b'u' | b'U' if css_url_start(bytes, index) => {
                    state = State::Url;
                    index += 4;
                }
                b'\\' => {
                    if index + 1 == bytes.len() {
                        return Err(format!("dangling CSS escape at byte {index}"));
                    }

                    index += 2;
                }
                open @ (b'{' | b'[' | b'(') => {
                    if stack.len() == MAX_CSS_NESTING {
                        return Err(format!(
                            "CSS nesting exceeds the limit of {MAX_CSS_NESTING} at byte {index}"
                        ));
                    }

                    stack.push(open);
                    index += 1;
                }
                close @ (b'}' | b']' | b')') => {
                    let expected_open = match close {
                        b'}' => b'{',
                        b']' => b'[',
                        b')' => b'(',
                        _ => unreachable!(),
                    };

                    if stack.pop() != Some(expected_open) {
                        return Err(format!("unmatched CSS delimiter at byte {index}"));
                    }

                    index += 1;
                }
                _ => index += 1,
            },
            State::Comment => {
                if bytes[index] == b'*' && bytes.get(index + 1) == Some(&b'/') {
                    state = State::Normal;
                    index += 2;
                } else {
                    index += 1;
                }
            }
            State::String(quote, url) => match bytes[index] {
                b'\\' => {
                    index += 1;

                    if bytes.get(index) == Some(&b'\r') && bytes.get(index + 1) == Some(&b'\n') {
                        index += 2;
                    } else if index < bytes.len() {
                        index += 1;
                    }
                }
                byte if byte == quote => {
                    state = if url { State::Url } else { State::Normal };
                    index += 1;
                }
                b'\n' | b'\r' | 0x0c => {
                    return Err(format!("unterminated CSS string at byte {index}"));
                }
                _ => index += 1,
            },
            State::Url => match bytes[index] {
                b'\\' => index = (index + 2).min(bytes.len()),
                quote @ (b'\'' | b'"') => {
                    state = State::String(quote, true);
                    index += 1;
                }
                b')' => {
                    state = State::Normal;
                    index += 1;
                }
                _ => index += 1,
            },
        }
    }

    match state {
        State::Comment => return Err("unterminated CSS comment".to_owned()),
        State::String(_, _) => return Err("unterminated CSS string".to_owned()),
        State::Url => return Err("unterminated CSS URL".to_owned()),
        State::Normal => {}
    }

    if let Some(open) = stack.last() {
        return Err(format!("unclosed CSS delimiter '{}'", char::from(*open)));
    }

    Ok(())
}
