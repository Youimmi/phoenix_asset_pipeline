use cssparser::{CowRcStr, ParseError, Parser, ParserInput, Token};
use lightningcss::{
    printer::PrinterOptions,
    stylesheet::{ParserOptions, StyleSheet},
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
        .and_then(|stylesheet| stylesheet.to_css(printer_opts).ok())
    {
        Some(output) => Ok(output.code.encode(env)),
        None => Ok(raw_css.encode(env)),
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

fn encode_classes<'a>(env: Env<'a>, classes: &[CowRcStr<'_>]) -> Term<'a> {
    let mut list = Term::list_new_empty(env);

    for class in classes.iter().rev() {
        list = list.list_prepend(class.as_ref());
    }

    list
}
