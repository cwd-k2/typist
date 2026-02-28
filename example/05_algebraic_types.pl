#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

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

# ── Pattern Matching (via _tag) ───────────────────────────
#
# Perl doesn't have built-in pattern matching, but _tag
# enables clean dispatch with given/when or if/elsif.

sub area ($shape) {
    my ($tag, $vals) = ($shape->{_tag}, $shape->{_values});
    if    ($tag eq 'Circle')    { 3.14159 * $vals->[0] ** 2 }
    elsif ($tag eq 'Rectangle') { $vals->[0] * $vals->[1] }
    else                        { die "Unknown shape: $tag" }
}

say "area(Circle(5)):      ", area(Circle(5));
say "area(Rectangle(3,4)): ", area(Rectangle(3, 4));

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
    my ($tag, $v) = ($e->{_tag}, $e->{_values});
    if    ($tag eq 'Lit') { $v->[0] }
    elsif ($tag eq 'Add') { eval_expr($v->[0]) + eval_expr($v->[1]) }
    elsif ($tag eq 'Mul') { eval_expr($v->[0]) * eval_expr($v->[1]) }
    else                  { die "Unknown expr: $tag" }
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
    if ($r->{_tag} eq 'Ok') {
        say "parse_int('$input'): Ok($r->{_values}[0])";
    } else {
        say "parse_int('$input'): Err($r->{_values}[0])";
    }
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
    if ($e->{_tag} eq 'Right') { "success: $e->{_values}[0]" }
    else                       { "error: $e->{_values}[0]" }
}

say "Right(200):         ", describe_either($ok);
say "Left('not found'):  ", describe_either($err);

# ── Nullary-like Constructors ─────────────────────────────
#
# Even single-field constructors carry typed values.
# For "enum-like" ADTs, use a unit value or literal.

BEGIN {
    datatype Color =>
        Red   => '(Str)',
        Green => '(Str)',
        Blue  => '(Str)';
}

my @palette = (Red("red"), Green("green"), Blue("blue"));
for my $c (@palette) {
    say "  $c->{_tag}: $c->{_values}[0]";
}
