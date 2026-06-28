use cssparser::{CowRcStr, ParseError, Parser, ParserInput, Token};
use lightningcss::{
    declaration::DeclarationBlock,
    printer::PrinterOptions,
    properties::{Property, PropertyId},
    rules::{CssRule, CssRuleList, supports::SupportsCondition},
    stylesheet::{MinifyOptions, ParserOptions, StyleSheet},
    vendor_prefix::VendorPrefix,
};
use rustler::{Binary, Encoder, Env, Error, NifResult, Term};

#[rustler::nif(schedule = "DirtyCpu")]
pub fn extract_class_names_from_css<'a>(env: Env<'a>, css: Binary<'a>) -> NifResult<Term<'a>> {
    let css_text = std::str::from_utf8(css.as_slice()).map_err(|_| Error::BadArg)?;

    let mut classes = Vec::with_capacity(64);
    let mut input = ParserInput::new(css_text);
    let mut parser = Parser::new(&mut input);

    parse_tokens(&mut classes, &mut parser);

    classes.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));

    Ok(encode_classes(env, &classes))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn minify_css<'a>(env: Env<'a>, raw_css: Binary<'a>) -> NifResult<Term<'a>> {
    let raw_css_text = std::str::from_utf8(raw_css.as_slice()).map_err(|_| Error::BadArg)?;

    let parser_opts = ParserOptions::default();
    let printer_opts = PrinterOptions {
        minify: true,
        ..PrinterOptions::default()
    };

    match StyleSheet::parse(raw_css_text, parser_opts)
        .ok()
        .and_then(|mut stylesheet| {
            unwrap_modern_supports(&mut stylesheet.rules);
            stylesheet.minify(MinifyOptions::default()).ok()?;
            remove_modern_fallbacks(&mut stylesheet.rules);
            stylesheet.to_css(printer_opts).ok()
        }) {
        Some(output) => Ok(output.code.encode(env)),
        None => Ok(raw_css.encode(env)),
    }
}

fn encode_classes<'a>(env: Env<'a>, classes: &[CowRcStr<'_>]) -> Term<'a> {
    let mut list = Term::list_new_empty(env);

    for class in classes.iter().rev() {
        list = list.list_prepend(class.as_ref());
    }

    list
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

fn parse_tokens<'i>(classes: &mut Vec<CowRcStr<'i>>, parser: &mut Parser<'i, '_>) {
    while let Ok(token) = parser.next_including_whitespace_and_comments() {
        match token {
            Token::CurlyBracketBlock | Token::Function(_) => {
                let _ = parser.parse_nested_block(|nested| {
                    parse_tokens(classes, nested);
                    Ok::<(), ParseError<'_, ()>>(())
                });
            }

            Token::Delim('.') => {
                if let Ok(Token::Ident(ident)) = parser.next_including_whitespace_and_comments() {
                    classes.push(ident.clone());
                }
            }

            _ => {}
        }
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
    let mut modern_properties = Vec::new();

    declarations.retain(|declaration| {
        let property_id = declaration.property_id();

        if modern_properties.contains(&property_id) {
            false
        } else {
            if property_uses_color_mix(declaration) {
                modern_properties.push(property_id);
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
