use ahash::{AHashMap, AHashSet, RandomState};
use lightningcss::{
    declaration::DeclarationBlock,
    printer::PrinterOptions,
    properties::{Property, PropertyId},
    rules::{CssRule, CssRuleList, supports::SupportsCondition},
    selector::{Component, PseudoClass, PseudoElement, Selector, SelectorList},
    stylesheet::{MinifyOptions, ParserOptions, StyleSheet},
    traits::{ParseWithOptions, ToCss},
    values::ident::Ident,
    vendor_prefix::VendorPrefix,
    visitor::{Visit, VisitTypes, Visitor},
};
use parcel_selectors::parser::NthOfSelectorData;
use rustler::{Binary, Encoder, Env, Term};

const CLASS_MARKER_BASE: &str = "__p";
const MAX_CSS_NESTING: usize = 128;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[derive(Debug)]
struct PreparedCss {
    class_counts: Vec<usize>,
    code: String,
    custom_property_counts: Vec<(String, usize)>,
    marker_classes: Vec<String>,
    marker_prefix: String,
}

struct SelectorClassProcessor {
    class_indices: AHashMap<String, (usize, usize)>,
    marker_prefix: String,
}

impl SelectorClassProcessor {
    fn marker() -> Self {
        Self {
            class_indices: AHashMap::new(),
            marker_prefix: class_marker_prefix(),
        }
    }

    fn process_class(&mut self, class: &mut Ident<'_>) {
        let class_name = class.0.as_ref();
        let index = match self.class_indices.get_mut(class_name) {
            Some((index, count)) => {
                *count += 1;
                *index
            }
            None => {
                let index = self.class_indices.len();
                self.class_indices.insert(class_name.to_owned(), (index, 1));
                index
            }
        };

        *class = Ident(format!("{}{index}_", self.marker_prefix).into());
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

    fn process_component(
        &mut self,
        component: &mut Component<'_>,
        depth: usize,
    ) -> Result<(), String> {
        match component {
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
}

impl<'i> Visitor<'i> for SelectorClassProcessor {
    type Error = String;

    fn visit_types(&self) -> VisitTypes {
        VisitTypes::SELECTORS | VisitTypes::SUPPORTS_CONDITIONS
    }

    fn visit_selector(&mut self, selector: &mut Selector<'i>) -> Result<(), Self::Error> {
        self.process_selector(selector, 0)
    }

    fn visit_supports_condition(
        &mut self,
        condition: &mut SupportsCondition<'i>,
    ) -> Result<(), Self::Error> {
        if let SupportsCondition::Selector(raw_selector) = condition {
            let mut selectors = SelectorList::parse_string_with_options(
                raw_selector.as_ref(),
                ParserOptions::default(),
            )
            .map_err(|error| format!("could not parse @supports selector(): {error:?}"))?;

            self.process_selectors(&mut selectors.0, 0)?;
            let selector = selectors
                .to_css_string(PrinterOptions {
                    minify: true,
                    ..PrinterOptions::default()
                })
                .map_err(|error| format!("could not print @supports selector(): {error}"))?;

            drop(selectors);
            *raw_selector = selector.into();

            Ok(())
        } else {
            condition.visit_children(self)
        }
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
        css_text(css).and_then(|css| {
            finalize_css(
                css,
                marker_prefix.as_slice(),
                &class_replacements,
                &variable_replacements,
            )
        }),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn prepare_css_nif<'a>(env: Env<'a>, raw_css: Binary<'a>) -> Term<'a> {
    encode_result(
        env,
        css_text(raw_css).and_then(prepare_css).map(|prepared| {
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

fn css_text(css: Binary<'_>) -> Result<&str, String> {
    std::str::from_utf8(css.as_slice()).map_err(|error| format!("CSS is not valid UTF-8: {error}"))
}

fn encode_result<'a, T: Encoder>(env: Env<'a>, result: Result<T, String>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
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

    for (class_name, (index, count)) in processor.class_indices {
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

fn print_stylesheet(stylesheet: &mut StyleSheet<'_>) -> Result<String, String> {
    stylesheet
        .to_css(PrinterOptions {
            minify: true,
            ..PrinterOptions::default()
        })
        .map(|output| output.code)
        .map_err(|error| format!("could not print CSS: {error}"))
}

fn finalize_css(
    css: &str,
    marker_prefix: &[u8],
    class_replacements: &[Binary<'_>],
    variable_replacements: &[(Binary<'_>, Binary<'_>)],
) -> Result<String, String> {
    let class_replacements = class_replacements
        .iter()
        .map(|replacement| {
            std::str::from_utf8(replacement.as_slice())
                .map_err(|error| format!("class replacement is not valid UTF-8: {error}"))
        })
        .collect::<Result<Vec<_>, _>>()?;

    let mut variables = AHashMap::with_capacity(variable_replacements.len());

    for (variable, replacement) in variable_replacements {
        let variable = std::str::from_utf8(variable.as_slice())
            .map_err(|error| format!("CSS variable is not valid UTF-8: {error}"))?;
        let replacement = std::str::from_utf8(replacement.as_slice())
            .map_err(|error| format!("CSS variable replacement is not valid UTF-8: {error}"))?;
        variables.insert(variable, replacement);
    }

    let bytes = css.as_bytes();
    let mut cursor = 0;
    let mut last = 0;
    let mut output = String::with_capacity(css.len());

    while cursor < bytes.len() {
        if !variables.is_empty() && matches!(bytes[cursor], b'\'' | b'"') {
            cursor = skip_css_string(bytes, cursor);
            continue;
        }

        if !class_replacements.is_empty()
            && bytes[cursor] == b'.'
            && bytes[cursor + 1..].starts_with(marker_prefix)
        {
            output.push_str(&css[last..cursor]);

            let mut index_cursor = cursor + marker_prefix.len() + 1;
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

            if !replacement.starts_with('.') {
                return Err(format!("invalid replacement for CSS class marker {index}"));
            }

            output.push_str(replacement);
            cursor = index_cursor + 1;
            last = cursor;
            continue;
        }

        if !variables.is_empty()
            && bytes[cursor] == b'-'
            && let Some(stop) = custom_property_end(bytes, cursor)
        {
            if let Some(replacement) = variables.get(&css[cursor..stop]) {
                output.push_str(&css[last..cursor]);
                output.push_str(replacement);
                last = stop;
            }

            cursor = stop;
        } else {
            cursor += 1;
        }
    }

    output.push_str(&css[last..]);
    Ok(output)
}

fn collect_custom_properties(css: &str) -> Vec<(String, usize)> {
    let bytes = css.as_bytes();
    let mut counts = AHashMap::new();
    let mut cursor = 0;

    while cursor < bytes.len() {
        if matches!(bytes[cursor], b'\'' | b'"') {
            cursor = skip_css_string(bytes, cursor);
        } else if bytes[cursor] == b'-'
            && let Some(stop) = custom_property_end(bytes, cursor)
        {
            let property = &css[cursor..stop];
            *counts.entry(property.to_owned()).or_insert(0) += 1;
            cursor = stop;
        } else {
            cursor += 1;
        }
    }

    let mut counts = counts.into_iter().collect::<Vec<_>>();
    counts.sort_unstable_by(|left, right| left.0.cmp(&right.0));
    counts
}

fn custom_property_end(bytes: &[u8], index: usize) -> Option<usize> {
    if index + 2 >= bytes.len()
        || bytes[index + 1] != b'-'
        || !css_variable_byte(bytes[index + 2])
        || (index > 0 && bytes[index - 1] == b'\\')
    {
        return None;
    }

    let mut stop = index + 3;

    while stop < bytes.len() && css_variable_byte(bytes[stop]) {
        stop += 1;
    }

    if custom_property_context(bytes, index, stop) {
        Some(stop)
    } else {
        None
    }
}

fn custom_property_context(bytes: &[u8], index: usize, stop: usize) -> bool {
    let next = skip_css_whitespace(bytes, stop);
    let previous = previous_non_whitespace(bytes, index);

    let declaration = bytes.get(next) == Some(&b':')
        && previous.is_none_or(|previous| matches!(bytes[previous], b'{' | b';' | b'('));

    let property_rule = bytes.get(next) == Some(&b'{')
        && previous.is_some_and(|end| {
            end >= 8
                && &bytes[end - 8..=end] == b"@property"
                && (end == 8 || !css_variable_byte(bytes[end - 9]))
        });

    let var_function = previous.is_some_and(|open| {
        open >= 3
            && bytes[open] == b'('
            && &bytes[open - 3..open] == b"var"
            && (open == 3 || !css_variable_byte(bytes[open - 4]))
    });

    declaration || property_rule || var_function
}

fn css_variable_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')
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

fn css_whitespace(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | 0x0c)
}

fn validate_css_structure(css: &str) -> Result<(), String> {
    #[derive(Clone, Copy)]
    enum State {
        Normal,
        Comment,
        String(u8),
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
                    state = State::String(quote);
                    index += 1;
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
            State::String(quote) => match bytes[index] {
                b'\\' => {
                    index += 1;

                    if bytes.get(index) == Some(&b'\r') && bytes.get(index + 1) == Some(&b'\n') {
                        index += 2;
                    } else if index < bytes.len() {
                        index += 1;
                    }
                }
                byte if byte == quote => {
                    state = State::Normal;
                    index += 1;
                }
                b'\n' | b'\r' | 0x0c => {
                    return Err(format!("unterminated CSS string at byte {index}"));
                }
                _ => index += 1,
            },
        }
    }

    match state {
        State::Comment => return Err("unterminated CSS comment".to_owned()),
        State::String(_) => return Err("unterminated CSS string".to_owned()),
        State::Normal => {}
    }

    if let Some(open) = stack.last() {
        return Err(format!("unclosed CSS delimiter '{}'", char::from(*open)));
    }

    Ok(())
}

fn matches_custom_property(property_id: &PropertyId<'_>, name: &str) -> bool {
    matches!(property_id, PropertyId::Custom(property) if property.as_ref() == name)
}

fn matches_webkit_appearance(property_id: &PropertyId<'_>) -> bool {
    matches!(property_id, PropertyId::Appearance(_))
        && property_id.prefix().contains(VendorPrefix::WebKit)
}

fn matches_webkit_hyphens(property_id: &PropertyId<'_>) -> bool {
    matches!(property_id, PropertyId::Hyphens(_))
        && property_id.prefix().contains(VendorPrefix::WebKit)
}

fn modern_supports(condition: &SupportsCondition) -> bool {
    match condition {
        SupportsCondition::And(conditions) => conditions.iter().all(modern_supports),
        SupportsCondition::Declaration { property_id, value } => {
            property_id == &PropertyId::Color && value.as_ref().contains("color-mix(")
        }
        SupportsCondition::Or(conditions) => tailwind_placeholder_supports(conditions),
        _ => false,
    }
}

fn property_condition(
    condition: &SupportsCondition,
    predicate: impl FnOnce(&PropertyId, &str) -> bool,
) -> bool {
    match condition {
        SupportsCondition::Declaration { property_id, value } => {
            predicate(property_id, value.as_ref())
        }
        _ => false,
    }
}

fn property_uses_color_mix(property: &Property<'_>) -> bool {
    property
        .value_to_css_string(PrinterOptions {
            minify: true,
            ..PrinterOptions::default()
        })
        .is_ok_and(|value| value.contains("color-mix("))
}

fn remove_fallback_declarations(declarations: &mut Vec<Property<'_>>) {
    if declarations.len() < 2 {
        return;
    }

    if declarations.len() == 2 {
        if declarations[0].property_id() != declarations[1].property_id() {
            return;
        }
    } else {
        let mut property_ids = AHashSet::with_capacity(declarations.len());

        if declarations
            .iter()
            .all(|declaration| property_ids.insert(declaration.property_id()))
        {
            return;
        }
    }

    let mut modern_properties = AHashSet::new();

    declarations.retain(|declaration| {
        let property_id = declaration.property_id();

        if modern_properties.contains(&property_id) {
            false
        } else {
            if property_uses_color_mix(declaration) {
                modern_properties.insert(property_id);
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
        match rule {
            CssRule::Container(container) => remove_modern_fallbacks(&mut container.rules),
            CssRule::LayerBlock(layer) => remove_modern_fallbacks(&mut layer.rules),
            CssRule::Media(media) => remove_modern_fallbacks(&mut media.rules),
            CssRule::Scope(scope) => remove_modern_fallbacks(&mut scope.rules),
            CssRule::StartingStyle(starting_style) => {
                remove_modern_fallbacks(&mut starting_style.rules)
            }
            CssRule::Style(style) => {
                remove_fallbacks_from_declaration_block(&mut style.declarations);
                remove_modern_fallbacks(&mut style.rules);
            }
            _ => {}
        }
    }
}

fn tailwind_legacy_property_condition(condition: &SupportsCondition<'_>) -> bool {
    match condition {
        SupportsCondition::Or(conditions) => {
            let mut moz = false;
            let mut webkit = false;

            for condition in conditions {
                moz |= tailwind_moz_legacy_property_condition(condition);
                webkit |= tailwind_webkit_legacy_property_condition(condition);

                if moz && webkit {
                    return true;
                }
            }

            false
        }
        _ => false,
    }
}

fn tailwind_moz_legacy_property_condition(condition: &SupportsCondition<'_>) -> bool {
    match condition {
        SupportsCondition::And(conditions) => {
            let mut color = false;
            let mut orient = false;

            for condition in conditions {
                orient |= property_condition(condition, |property_id, value| {
                    matches_custom_property(property_id, "-moz-orient") && value == "inline"
                });

                color |= matches!(condition, SupportsCondition::Not(condition) if property_condition(condition, |property_id, value| {
                    property_id == &PropertyId::Color && value.contains("rgb(from red r g b")
                }));

                if color && orient {
                    return true;
                }
            }

            false
        }
        _ => false,
    }
}

fn tailwind_placeholder_supports(conditions: &[SupportsCondition]) -> bool {
    let mut fallback = false;
    let mut support = false;

    for condition in conditions {
        fallback |= matches!(condition, SupportsCondition::Not(condition) if property_condition(condition, |property_id, value| {
            matches_webkit_appearance(property_id) && value == "-apple-pay-button"
        }));

        support |= property_condition(condition, |property_id, value| {
            matches_custom_property(property_id, "contain-intrinsic-size") && value == "1px"
        });

        if fallback && support {
            return true;
        }
    }

    false
}

fn tailwind_webkit_legacy_property_condition(condition: &SupportsCondition<'_>) -> bool {
    match condition {
        SupportsCondition::And(conditions) => {
            let mut hyphens = false;
            let mut margin_trim = false;

            for condition in conditions {
                hyphens |= property_condition(condition, |property_id, value| {
                    matches_webkit_hyphens(property_id) && value == "none"
                });

                margin_trim |= matches!(condition, SupportsCondition::Not(condition) if property_condition(condition, |property_id, value| {
                    matches_custom_property(property_id, "margin-trim") && value == "inline"
                }));

                if hyphens && margin_trim {
                    return true;
                }
            }

            false
        }
        _ => false,
    }
}

fn unwrap_modern_supports(rules: &mut CssRuleList<'_>) {
    let mut next = Vec::with_capacity(rules.0.len());

    for mut rule in rules.0.drain(..) {
        match &mut rule {
            CssRule::Container(container) => {
                unwrap_modern_supports(&mut container.rules);
                next.push(rule);
            }

            CssRule::LayerBlock(layer) => {
                unwrap_modern_supports(&mut layer.rules);
                next.push(rule);
            }

            CssRule::Media(media) => {
                unwrap_modern_supports(&mut media.rules);
                next.push(rule);
            }

            CssRule::Scope(scope) => {
                unwrap_modern_supports(&mut scope.rules);
                next.push(rule);
            }

            CssRule::StartingStyle(starting_style) => {
                unwrap_modern_supports(&mut starting_style.rules);
                next.push(rule);
            }

            CssRule::Style(style) => {
                unwrap_modern_supports(&mut style.rules);
                next.push(rule);
            }

            CssRule::Supports(supports) => {
                unwrap_modern_supports(&mut supports.rules);

                if tailwind_legacy_property_condition(&supports.condition) {
                    continue;
                } else if modern_supports(&supports.condition) {
                    next.append(&mut supports.rules.0);
                } else {
                    next.push(rule);
                }
            }

            _ => next.push(rule),
        }
    }

    rules.0 = next;
}
