use anyhow::{ensure, Context, Result};
use serde_json::Value;

fn input_matches(pattern: &str, text: &str) -> Result<bool> {
    // Source validators use JavaScript regular expressions, including syntax
    // that a Rust regex engine would interpret differently or reject.
    let runtime = rquickjs::Runtime::new()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(100);
    runtime.set_interrupt_handler(Some(Box::new(move || {
        std::time::Instant::now() >= deadline
    })));
    let context = rquickjs::Context::full(&runtime)?;
    context.with(|ctx| -> Result<bool> {
        let expression = format!(
            "new RegExp({}).test({})",
            serde_json::to_string(pattern)?,
            serde_json::to_string(text)?
        );
        Ok(ctx.eval(expression)?)
    })
}

fn options(definition: &Value) -> impl Iterator<Item = &Value> {
    definition["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|value| value.is_boolean() || value.is_number() || value.is_string())
}

fn valid(definition: &Value, value: &Value) -> bool {
    match definition["type"].as_str() {
        Some("select") => options(definition).any(|option| option == value),
        Some("switch") => value.is_boolean(),
        Some("input") => value.as_str().is_some_and(|text| {
            definition["validator"]
                .as_str()
                .is_none_or(|pattern| input_matches(pattern, text).unwrap_or(false))
        }),
        _ => false,
    }
}

pub fn effective(definition: &Value, saved: &Value) -> Value {
    if definition.is_null() {
        return saved.clone(); // Settings used by scripts without a declared control.
    }
    if valid(definition, saved) {
        return saved.clone();
    }
    let default = &definition["default"];
    if valid(definition, default) {
        return default.clone();
    }
    match definition["type"].as_str() {
        Some("select") => options(definition).next().cloned().unwrap_or(Value::Null),
        Some("switch") => Value::Bool(false),
        Some("input") => "".into(),
        _ => default.clone(),
    }
}

pub fn required_value(definition: &Value, value: &Value) -> Result<()> {
    ensure!(
        valid(definition, value),
        "Invalid value for this source setting"
    );
    Ok(())
}

pub fn ensure_editable(definition: &Value) -> Result<()> {
    definition["type"]
        .as_str()
        .filter(|kind| matches!(*kind, "select" | "switch" | "input"))
        .context("Unknown source setting")?;
    Ok(())
}
