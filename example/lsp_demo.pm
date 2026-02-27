package LSP::Demo;
use v5.40;
use lib 'lib';
use Typist;

# This file demonstrates features visible via the Typist LSP server:
#   - Hover shows type signatures
#   - Completion suggests type names inside :Type(), :Params(), :Returns()
#   - Diagnostics flag type errors (alias cycles, undeclared type vars)
#   - Gradual typing: return type propagation, variable symbol resolution

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

# ── Gradual typing: return type flows into variable init ──

# find_email returns Email (= Str), so $result gets type Str → OK
my $result :Type(Email) = find_email(1001);

# ── Gradual typing: variable symbol at call site ──

# $email is :Type(Email), find_email accepts UserId → diagnostic expected
# (This intentionally shows a type mismatch for LSP demonstration)
# find_email($email);

# ── Flow typing: inferred variable from function return ──

# find_email returns Email (= Str), so $found_email is inferred as Str
# without any :Type annotation. Hover shows: $found_email: Str (inferred)
my $found_email = find_email(1001);

# ── Unannotated helper — hover shows: sub format_output(Any) -> Any !Eff(*) ──

sub format_output ($s) {
    ">> $s <<";
}

# Return type is Any → assignment check skipped (no false positive)
my $formatted :Type(Str) = format_output($found_email);

1;
