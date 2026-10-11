///|
pub extend SyncMessage with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend SyncMessage with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend SyncMessage with @debug.Debug::{to_repr}

///|
pub extend Message with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend Message with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend Message with @debug.Debug::{to_repr}

///|
pub extend MetaClientState with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend MetaClientState with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend MetaClientState with @debug.Debug::{to_repr}

///|
pub extend AwarenessChange with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend AwarenessChange with Eq::{not_equal}

///|
#deprecated("Use `Repr(x)` instead", skip_current_package=true)
#doc(hidden)
pub extend AwarenessChange with @debug.Debug::{to_repr}
