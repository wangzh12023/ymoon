///|
pub extend Any with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend Any with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend Any with @debug.Debug::{to_repr}

///|
pub extend DecodeError with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend DecodeError with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend DecodeError with @debug.Debug::{to_repr}

///|
pub extend JsonError with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend JsonError with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend JsonError with @debug.Debug::{to_repr}

///|
pub extend DecodeError with Show::{to_string}

///|
pub extend JsonError with Show::{to_string}
