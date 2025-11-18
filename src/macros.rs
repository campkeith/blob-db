#[macro_export] macro_rules!
log_ret_err{($result: expr) => {
    log_err_ret_val!($result, Err(Status::InternalError))
}}

#[macro_export] macro_rules!
log_err_ret_val{($result: expr, $err_ret_val: expr) => {
    match $result {
        Ok(val) => val,
        Err(error) => {
            log_err!(error);
            return $err_ret_val;
        }
    }
}}

#[macro_export] macro_rules!
log_err{($error: expr) => {
    let (file, line, error) = (file!(), line!(), $error);
    eprintln!("{file}:{line}: {error:?}: {error}");
}}

#[macro_export] macro_rules!
map_ret_err{($result: expr, $err_kind: expr, $err_ret_val: expr) => {
    if let Err(ref error) = $result {
        if error.kind() == $err_kind {
            return $err_ret_val;
        }
    }
}}

#[macro_export] macro_rules!
log_call{($name: path[$($params: ident), *] -> $out: expr) => {{
    let name = stringify!($name);
    let param_strs: [String; _] = [$(
        format!("{}={}", stringify!($params), $params.trace()),
    )*];
    let params_str = param_strs.join(", ");
    println!("{name}({params_str}):");
    let out = (|| $out)();
    let out_str = out.trace();
    println!("{name} -> {out_str}");
    out
}}}
