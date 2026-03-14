#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;

# ═══════════════════════════════════════════════════════════
#  05 — Algebraic Data Types
#
#  datatype defines tagged unions (sum types) with typed
#  constructors. Each variant carries a fixed number of
#  typed fields, and values are blessed hashrefs with
#  _tag and _values.
#
#    datatype Shape =>
#        Circle    => '(Int)',
#        Rectangle => '(Int, Int)';
# ═══════════════════════════════════════════════════════════

# ── Basic ADT ─────────────────────────────────────────────

BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)';
}

my $c = Circle(5);
my $r = Rectangle(3, 4);

say "Circle:    tag=$c->{_tag}  radius=$c->{_values}[0]";
say "Rectangle: tag=$r->{_tag}  w=$r->{_values}[0] h=$r->{_values}[1]";

# Constructor validates field types
eval { Circle("big") };
say "Circle('big'):      $@" if $@;

eval { Rectangle(3, "four") };
say "Rectangle(3,'four'): $@" if $@;

# ── Pattern Matching (match expression) ──────────────────
#
# `match` dispatches on _tag and splats _values into the
# handler. Use _ as the fallback arm.

sub area ($shape) {
    match $shape,
        Circle    => sub ($r)     { 3.14159 * $r ** 2 },
        Rectangle => sub ($w, $h) { $w * $h };
}

say "area(Circle(5)):      ", area(Circle(5));
say "area(Rectangle(3,4)): ", area(Rectangle(3, 4));

# Fallback arm
sub describe ($shape) {
    match $shape,
        Circle => sub ($r) { "circle with radius $r" },
        _      => sub      { "some other shape" };
}

say "describe(Circle(5)):      ", describe(Circle(5));
say "describe(Rectangle(3,4)): ", describe(Rectangle(3, 4));

# ── ADT with Multiple Types ──────────────────────────────

BEGIN {
    datatype Expr =>
        Lit => '(Int)',
        Add => '(Expr, Expr)',
        Mul => '(Expr, Expr)';
}

# 2 + 3 * 4
my $expr = Add(Lit(2), Mul(Lit(3), Lit(4)));

sub eval_expr ($e) {
    match $e,
        Lit => sub ($n)      { $n },
        Add => sub ($l, $r)  { eval_expr($l) + eval_expr($r) },
        Mul => sub ($l, $r)  { eval_expr($l) * eval_expr($r) };
}

say "2 + 3 * 4 = ", eval_expr($expr);

# ── ADT with Str Fields ──────────────────────────────────

BEGIN {
    datatype Result =>
        Ok  => '(Str)',
        Err => '(Str)';
}

sub parse_int ($s) {
    $s =~ /^\d+$/ ? Ok($s) : Err("not a number: $s");
}

for my $input ("42", "abc") {
    my $r = parse_int($input);
    my $msg = match $r,
        Ok  => sub ($v) { "Ok($v)" },
        Err => sub ($v) { "Err($v)" };
    say "parse_int('$input'): $msg";
}

# ── Parameterized ADTs ──────────────────────────────────
#
# Type parameters make ADTs polymorphic. Use quoted name
# with brackets: datatype 'Name[T]' => ...
# Constructors infer type arguments from actual values.

BEGIN {
    datatype 'Option[T]' =>
        Some => '(T)',
        None => '()';
}

my $x = Some(42);       # T inferred as Int
my $y = Some("hello");  # T inferred as Str
my $z = None();          # no inference needed

say "Some(42):      tag=$x->{_tag}  val=$x->{_values}[0]";
say "Some('hello'): tag=$y->{_tag}  val=$y->{_values}[0]";
say "None():        tag=$z->{_tag}";

# Type checking with instantiated types
use Typist::Type::Data;
use Typist::Type::Atom;

my $opt_int = Typist::Registry->lookup_datatype('Option')
    ->instantiate(Typist::Type::Atom->new('Int'));

say "Option[Int] contains Some(42)?      ", $opt_int->contains($x) ? 'yes' : 'no';
say "Option[Int] contains Some('hello')? ", $opt_int->contains($y) ? 'yes' : 'no';
say "Option[Int] contains None()?        ", $opt_int->contains($z) ? 'yes' : 'no';

# ── Multi-Parameter ADTs ─────────────────────────────────

BEGIN {
    datatype 'Either[L, R]' =>
        Left  => '(L)',
        Right => '(R)';
}

my $ok  = Right(200);
my $err = Left("not found");

sub describe_either ($e) {
    match $e,
        Right => sub ($v) { "success: $v" },
        Left  => sub ($v) { "error: $v" };
}

say "Right(200):         ", describe_either($ok);
say "Left('not found'):  ", describe_either($err);

# ── Nullary ADTs (enumerations) ───────────────────────────
#
# All-nullary constructors model pure enumerations.
# Each variant takes zero arguments.

BEGIN {
    datatype Color => Red => '()', Green => '()', Blue => '()';
}

my @palette = (Red(), Green(), Blue());
for my $c (@palette) {
    say "  Color: $c->{_tag}";
}

# Match works naturally with nullary ADTs
my $favorite = Blue();
my $name = match $favorite,
    Red   => sub { "crimson" },
    Green => sub { "emerald" },
    Blue  => sub { "sapphire" };

say "Blue is: $name";

# Exhaustiveness warning — try commenting out a branch!

# ── GADTs (Generalized Algebraic Data Types) ──────────────
#
# GADT constructors specify per-constructor return types using
# the '->' syntax. This lets each constructor constrain the
# type parameter to a specific type.
#
#   datatype 'Expr[A]' =>
#       IntLit  => '(Int) -> Expr[Int]',    # A = Int
#       BoolLit => '(Bool) -> Expr[Bool]';  # A = Bool
#
# At runtime, forced type_args override inference.

BEGIN {
    datatype 'TypedExpr[A]' =>
        TInt    => '(Int) -> TypedExpr[Int]',
        TBool   => '(Bool) -> TypedExpr[Bool]',
        TAdd    => '(TypedExpr[Int], TypedExpr[Int]) -> TypedExpr[Int]',
        TIf     => '(TypedExpr[Bool], TypedExpr[A], TypedExpr[A]) -> TypedExpr[A]';
}

my $lit = TInt(42);
say "TInt(42):   tag=$lit->{_tag}  type_arg=", $lit->{_type_args}[0]->to_string;

my $b = TBool(1);
say "TBool(1):   tag=$b->{_tag}  type_arg=", $b->{_type_args}[0]->to_string;

my $sum = TAdd(TInt(1), TInt(2));
say "TAdd(1, 2): tag=$sum->{_tag}  type_arg=", $sum->{_type_args}[0]->to_string;

# is_gadt predicate
my $dt = Typist::Registry->lookup_datatype('TypedExpr');
say "TypedExpr is GADT? ", $dt->is_gadt ? 'yes' : 'no';
say "Shape is GADT?     ", Typist::Registry->lookup_datatype('Shape')->is_gadt ? 'yes' : 'no';

# Match works normally with GADTs
sub eval_typed ($e) {
    match $e,
        TInt    => sub ($n)       { $n },
        TBool   => sub ($b)       { $b },
        TAdd    => sub ($l, $r)   { eval_typed($l) + eval_typed($r) },
        TIf     => sub ($c, $t, $f) { eval_typed($c) ? eval_typed($t) : eval_typed($f) };
}

say "eval TAdd(TInt(1), TInt(2)) = ", eval_typed($sum);
say "eval TIf(TBool(1), TInt(10), TInt(20)) = ",
    eval_typed(TIf(TBool(1), TInt(10), TInt(20)));
