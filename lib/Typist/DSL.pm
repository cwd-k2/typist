package Typist::DSL;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Struct;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;
use Typist::Type::Newtype;
use Typist::Type::Row;
use Typist::Type::Eff;

use Exporter 'import';

our @EXPORT = qw(
    Int Str Num Bool Any Void Never Undef
    ArrayRef HashRef Maybe Tuple Ref
    Struct Func Literal TVar Alias
    Row Eff
    T U V A B K
);

our @EXPORT_OK = @EXPORT;

our %EXPORT_TAGS = (
    types => [qw(
        Int Str Num Bool Any Void Never Undef
        ArrayRef HashRef Maybe Tuple Ref
        Struct Func Literal TVar Alias
        Row Eff
    )],
);

# ── Atom Constants ──────────────────────────────

use constant Int   => Typist::Type::Atom->new('Int');
use constant Str   => Typist::Type::Atom->new('Str');
use constant Num   => Typist::Type::Atom->new('Num');
use constant Bool  => Typist::Type::Atom->new('Bool');
use constant Any   => Typist::Type::Atom->new('Any');
use constant Void  => Typist::Type::Atom->new('Void');
use constant Never => Typist::Type::Atom->new('Never');
use constant Undef => Typist::Type::Atom->new('Undef');

# ── Type Variable Constants ─────────────────────

use constant T => Typist::Type::Var->new('T');
use constant U => Typist::Type::Var->new('U');
use constant V => Typist::Type::Var->new('V');
use constant A => Typist::Type::Var->new('A');
use constant B => Typist::Type::Var->new('B');
use constant K => Typist::Type::Var->new('K');

# ── Parametric Constructors ─────────────────────

sub ArrayRef :prototype(@) {
    Typist::Type::Param->new('ArrayRef', @_);
}

sub HashRef :prototype(@) {
    Typist::Type::Param->new('HashRef', @_);
}

sub Maybe :prototype($) {
    Typist::Type::Param->new('Maybe', @_);
}

sub Tuple :prototype(@) {
    Typist::Type::Param->new('Tuple', @_);
}

sub Ref :prototype($) {
    Typist::Type::Param->new('Ref', @_);
}

# ── Structural Type ─────────────────────────────

sub Struct :prototype(%) {
    Typist::Type::Struct->new(@_);
}

# ── Function Type ───────────────────────────────

sub Func :prototype(@) {
    my @args = @_;
    my $returns;
    # Extract 'returns => $type' from argument list
    for my $i (0 .. $#args) {
        if (!ref $args[$i] && $args[$i] eq 'returns') {
            $returns = $args[$i + 1];
            splice @args, $i, 2;
            last;
        }
    }
    die "Typist::DSL::Func requires 'returns => Type'\n" unless $returns;
    Typist::Type::Func->new(\@args, $returns);
}

# ── Literal Type ────────────────────────────────

sub Literal :prototype($) {
    my ($value) = @_;
    require Scalar::Util;
    my $base_type = Scalar::Util::looks_like_number($value) ? 'Num' : 'Str';
    if ($base_type eq 'Num' && $value == int($value)) {
        $base_type = 'Int';
    }
    Typist::Type::Literal->new($value, $base_type);
}

# ── Type Variable Constructor ───────────────────

sub TVar :prototype($;%) {
    my ($name, %opts) = @_;
    Typist::Type::Var->new($name, %opts);
}

# ── Alias Reference ─────────────────────────────

sub Alias :prototype($) {
    my ($name) = @_;
    Typist::Type::Alias->new($name);
}

# ── Effect Types ────────────────────────────────

sub Row :prototype(%) {
    Typist::Type::Row->new(@_);
}

sub Eff :prototype($) {
    my ($row) = @_;
    Typist::Type::Eff->new($row);
}

1;
