///|
pub extend ID with Eq::{equal}

///|
pub extend ID with Compare::{compare}

///|
pub extend ID with Hash::{hash}

///|
#deprecated("Use operators instead", skip_current_package=true)
#doc(hidden)
pub extend ID with Eq::{not_equal}

///|
#deprecated("Use operators instead", skip_current_package=true)
#doc(hidden)
pub extend ID with Compare::{op_lt, op_le, op_ge, op_gt}

///|
#deprecated("Use the trait method instead", skip_current_package=true)
#doc(hidden)
pub extend ID with Hash::{hash_combine}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend ID with @debug.Debug::{to_repr}

///|
pub extend TypeRef with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend TypeRef with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend TypeRef with @debug.Debug::{to_repr}

///|
pub extend DeleteItem with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend DeleteItem with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend DeleteItem with @debug.Debug::{to_repr}

///|
pub extend TypeError with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend TypeError with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend TypeError with @debug.Debug::{to_repr}

///|
pub extend DecodedStruct with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend DecodedStruct with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend DecodedStruct with @debug.Debug::{to_repr}

///|
pub extend TypeError with Show::{to_string}
