package LSP::Demo;
use v5.40;
use lib 'lib';
use Typist;

# ═══════════════════════════════════════════════════════════
#  LSP Demo — Hover, Completion, Diagnostics
#
#  Open this file in an editor with the Typist LSP server.
#
#  Features demonstrated:
#    Hover       — shows type signatures on functions/variables
#    Completion  — suggests type names inside :Type()
#    Diagnostics — flags type errors, alias cycles, etc.
#    Flow typing — inferred variable types from function returns
# ═══════════════════════════════════════════════════════════

# ── Typedef — hover shows: type Email = Str ───────────────

BEGIN {
    typedef Email  => 'Str';
    typedef UserId => 'Int';
    typedef Person => 'Record(name => Str, age => Int)';
}

# ── Typed variables — hover shows: $user_id: UserId ──────

my $user_id :Type(UserId) = 1001;
my $email   :Type(Email)  = 'alice@example.com';
my $age     :Type(Int)    = 30;

# ── Typed function — hover shows: sub find_email(UserId) -> Email

sub find_email :Type((UserId) -> Email) ($id) {
    "user_${id}\@example.com";
}

# ── Generic function — hover shows: sub identity<T>(T) -> T

sub identity :Type(<T>(T) -> T) ($x) {
    $x;
}

# ── Bounded generic — hover shows: sub add<T: Num>(T, T) -> T

sub add :Type(<T: Num>(T, T) -> T) ($a, $b) {
    $a + $b;
}

# ── Return type propagation ───────────────────────────────
# find_email returns Email (= Str), so $result has type Email

my $result :Type(Email) = find_email(1001);

# ── Flow typing — hover shows: $found: Str (inferred) ────
# No :Type annotation, but Typist infers from function return

my $found = find_email(1001);

# ── Literal inference — hover shows: $count: Int ──────────

my $count = 42;
my $label = "hello";

# ── Unannotated — hover shows: sub helper(Any) -> Any ![*]

sub helper ($s) {
    ">> $s <<";
}

# Return type Any → no false positive on assignment
my $formatted :Type(Str) = helper($found);

# ── Type error (uncomment to see diagnostic) ──────────────
# find_email($email);   # Email (Str) where UserId (Int) expected

1;
