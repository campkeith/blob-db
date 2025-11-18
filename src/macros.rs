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
log_call{
    ($self: ident . $name: ident ($($param: ident), *)
            -> $out: expr) => {
        log_call!(core: $self.$name($($param), *) -> $out)
    };

    ($name: ident ($($param: ident), *) -> $out: expr) => {
        log_call!(core: .$name($($param), *) -> $out)
    };

    (core: $($self: ident)? . $name: ident ($($param: ident), *)
            -> $out: expr) => {{
        let param_strs: [String; _] = [$(
            format!("{}={:?}", stringify!($param), $param),
        )*];
        let name = stringify!($name);
        let base = log_call!(
            if $($self)? then {format!("{:?}.{name}", $($self)?)}
            else {format!("{name}")}
        );
        println!("{base}({}):", param_strs.join(", "));
        let out = (|| $out)();
        println!("{base} -> {:?}", out);
        out
    }};

    (if $pred: ident then {$a: expr} else {$b: expr}) => {$a};
    (if then {$a: expr} else {$b: expr}) => {$b};
}
