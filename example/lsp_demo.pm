package LSP::Demo;
use v5.40;
use lib 'lib';
use Typist;

# This file demonstrates features visible via the Typist LSP server:
#   - Hover shows type signatures
#   - Completion suggests type names inside :Type(), :Params(), :Returns()
#   - Diagnostics flag type errors (alias cycles, undeclared type vars)

# ── Typedef — hover shows: type Email = Str ──────

BEGIN {
    typedef Email  => 'Str';
    typedef UserId => 'Int';
}

# ── Typed variable — hover shows: $user_id: UserId

my $user_id :Type(UserId) = 1001;
my $email   :Type(Email)  = 'alice@example.com';

# ── Typed function — hover shows: sub find_email(UserId) -> Email

sub find_email :Params(UserId) :Returns(Email) ($id) {
    "user_${id}\@example.com";
}

# ── Generic function — hover shows: sub identity<T>(T) -> T

sub identity :Generic(T) :Params(T) :Returns(T) ($x) {
    $x;
}

1;
