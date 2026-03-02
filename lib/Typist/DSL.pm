package Typist::DSL;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
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
    Record Func Literal TVar Alias
    Row Eff
    T U V A B K
);

our @EXPORT_OK = @EXPORT;

our %EXPORT_TAGS = (
    types => [qw(
        Int Str Num Bool Any Void Never Undef
        ArrayRef HashRef Maybe Tuple Ref
        Record Func Literal TVar Alias
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

sub Record :prototype(%) {
    Typist::Type::Record->new(@_);
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

__END__

=head1 NAME

Typist::DSL - Type constructors and operator overloading for Typist

=head1 SYNOPSIS

    use Typist::DSL;

    # Atom constants
    my $t = Int;              # Typist::Type::Atom('Int')

    # Type operators (via overloading on Typist::Type)
    my $union = Int | Str;    # Union type
    my $inter = A & B;        # Intersection type

    # Parametric constructors
    my $arr  = ArrayRef(Int);
    my $hash = HashRef(Str, Int);
    my $fn   = Func(Int, Int, returns => Bool);
    my $st   = Struct(name => Str, age => Int);

    # typedef / newtype with DSL
    typedef Name => Str;
    newtype UserId => Int;

=head1 DESCRIPTION

Typist::DSL exports atom type constants, type variable constants, and
parametric type constructors. Combined with the operator overloading
defined in L<Typist::Type>, this enables a concise DSL for building type
expressions in Perl code.

=head1 EXPORTS

All symbols are exported by default.

=head2 Atom Constants

C<Int>, C<Str>, C<Num>, C<Bool>, C<Any>, C<Void>, C<Never>, C<Undef>

Each is a singleton L<Typist::Type::Atom> instance.

=head2 Type Variable Constants

C<T>, C<U>, C<V>, C<A>, C<B>, C<K>

Each is a L<Typist::Type::Var> instance.

=head2 Parametric Constructors

=over 4

=item C<ArrayRef(T)>

=item C<HashRef(K, V)>

=item C<Maybe(T)>

=item C<Tuple(T, ...)>

=item C<Ref(T)>

=item C<Struct(key =E<gt> T, ...)>

=item C<Func(A, B, ..., returns =E<gt> R)>

=item C<Literal(value)>

=item C<TVar(name, %opts)>

=item C<Alias(name)>

=item C<Row(labels)>

=item C<Eff(row)>

=back

=head2 Type Operators

Provided by L<Typist::Type> overloading (available on all type objects):

    Int | Str          # Union
    Readable & Writable  # Intersection
    "$type"            # Stringify

=head1 SEE ALSO

L<Typist>, F<docs/type-system.md>

=cut
