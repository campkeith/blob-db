#[macro_export] macro_rules! log_err {
    (? $result:expr) => {{
        match $result {
            Ok(val) => val,
            Err(error) => return Err(log_err!(map(error))),
        }
    }};

    (map($error:expr)) => {{
        log_err!($error);
        Status::InternalError
    }};

    ($error:expr) => {{
        let (error, file, line) = ($error, file!(), line!());
        eprintln!("{file}:{line}: {error:?}: {error}")
    }};
}

#[macro_export] macro_rules! log_call {
    ($({named_inner=$inner:ident})?
        $vis:vis fn $name:ident $(<$life:lifetime>)?
            ($($param:ident: $param_ty:ty),*) $($rem:tt)*) => {
        log_call!(core: $({$inner})?
            $vis fn $name $(<$life>)? ($(, $param: $param_ty)*) $($rem)*);
    };

    ($({named_inner=$inner:ident})?
        $vis:vis fn $name:ident $(<$life:lifetime>)?
            ( & $($self_life:lifetime)? $self:ident
            $(, $param:ident: $param_ty:ty)*) $($rem:tt)*) => {
        log_call!(core: $({$inner})?
            $vis fn $name $(<$life>)?
            ((& $($self_life)?) $self $(, $param: $param_ty)*) $($rem)*);
    };

    ($({named_inner=$inner:ident})?
        $vis:vis fn $name:ident $(<$life:lifetime>)?
            ( & $($self_life:lifetime)? mut $self:ident
            $(, $param:ident: $param_ty:ty)*) $($rem:tt)*) => {
        log_call!(core: $({$inner})?
            $vis fn $name $(<$life>)?
            ((& $($self_life)? mut) $self $(, $param: $param_ty)*) $($rem)*);
    };

    (core: $({$inner:ident})?
        $vis:vis fn $name:ident $(<$life:lifetime>)?
            ( $(($($mod:tt)*) $self:ident)? $(, $param:ident: $param_ty:ty)*)
            $(-> $return_ty:ty)? $body:block) => {
        $vis fn $name $(<$life>)?
                ($($($mod)* $self,)? $($param: $param_ty),*) $(-> $return_ty)? {
            let param_strs: [String; _] = [$(
                format!("{}={:?}", stringify!($param), $param),
            )*];
            let name = stringify!($name);
            let base = log_call!(
                if $($self)? {format!("{:?}.{name}", $($self)?)}
                else {format!("{name}")}
            );
            println!("{base}({}):", param_strs.join(", "));
            let out = log_call!(
                if $($inner)? {log_call!(
                    if $($self)? {$($self.)? $($inner)? ($($param),*)}
                    else {{Self:: $($inner)? ($($param),*)}}
                )} else {
                    (|| $body)()
                }
            );
            println!("{base} -> {out:?}");
            out
        }

        log_call!(if $($inner)? {
            fn $($inner)? $(<$life>)?
                ($($($mod)* $self,)? $($param: $param_ty),*) $(-> $return_ty)?
                $body
        });
    };

    (if $pred:ident {$a:expr} else {$b:expr}) => {$a};
    (if {$a:expr} else {$b:expr}) => {$b};

    (if $pred:ident {$item:item}) => {$item};
    (if $item:tt) => {};
}
