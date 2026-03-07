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
    Int Str Double Num Bool Any Void Never Undef
    ArrayRef HashRef Array Hash Maybe Tuple Ref
    Record Literal
    optional
);

our @EXPORT_OK = qw(
    T U V A B K
    TVar Alias Row Eff Func Handler
);

our %EXPORT_TAGS = (
    all      => [@EXPORT, @EXPORT_OK],
    types    => [@EXPORT],
    vars     => [qw(T U V A B K)],
    internal => [qw(TVar Alias Row Eff Func)],
);

# ── Atom Constants ──────────────────────────────

use constant Int    => Typist::Type::Atom->new('Int');
use constant Str    => Typist::Type::Atom->new('Str');
use constant Double => Typist::Type::Atom->new('Double');
use constant Num    => Typist::Type::Atom->new('Num');
use constant Bool   => Typist::Type::Atom->new('Bool');
use constant Any    => Typist::Type::Atom->new('Any');
use constant Void   => Typist::Type::Atom->new('Void');
use constant Never  => Typist::Type::Atom->new('Never');
use constant Undef  => Typist::Type::Atom->new('Undef');

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

sub Array :prototype(@) {
    Typist::Type::Param->new('Array', @_);
}

sub Hash :prototype(@) {
    Typist::Type::Param->new('Hash', @_);
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

# ── Handler Type ───────────────────────────────

sub Handler :prototype($) {
    Typist::Type::Param->new('Handler', @_);
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
    my $base_type = Scalar::Util::looks_like_number($value) ? 'Double' : 'Str';
    if ($base_type eq 'Double' && $value == int($value)) {
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

# ── Optional Field Marker ──────────────────────

sub optional :prototype($$) ($name, $type) { ("${name}?", $type) }

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

Typist::DSL - Type constructors for tests (internal, not user-facing)

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

=head1 ATOM CONSTANTS

Exported by default. Each is a singleton L<Typist::Type::Atom> instance.
Subtype hierarchy: C<< Bool <: Int <: Double <: Num <: Any >>, C<< Str <: Any >>,
C<< Undef <: Any >>.

=head2 Int

Integer type.

=head2 Str

String type.

=head2 Double

Floating-point type. Float and exponential literals infer as C<Double>.

=head2 Num

Numeric supertype (encompasses C<Int> and C<Double>).

=head2 Bool

Boolean type. Widens to C<Int> for unannotated variables
(0/1 are numbers in Perl).

=head2 Any

Top type. Compatible with all types. Used in gradual typing.

=head2 Void

Unit return type for functions with no meaningful return value.

=head2 Never

Bottom type. Subtype of all types. Used for functions that never return.

=head2 Undef

The undefined value type. C<Maybe[T]> is sugar for C<T | Undef>.

=head1 PARAMETRIC CONSTRUCTORS

Exported by default.

=head2 ArrayRef

    ArrayRef(Int)

Scalar reference to an array. What C<[LIST]> produces.

=head2 HashRef

    HashRef(Str, Int)

Scalar reference to a hash. What C<+{LIST}> produces.

=head2 Array

    Array(Int)

List type. What C<grep>/C<map>/C<sort>/C<@deref> produce.
C<[Array[T]]> flattens to C<ArrayRef[T]>.
C<Array> is NOT a subtype of C<ArrayRef>.

=head2 Hash

    Hash(Str, Int)

List type for hash entries. Independent from C<HashRef>.

=head2 Maybe

    Maybe(Str)

Nullable type. Equivalent to C<T | Undef>.

=head2 Tuple

    Tuple(Int, Str, Bool)

Fixed-length heterogeneous array reference type.

=head2 Ref

    Ref(Int)

Generic scalar reference type.

=head2 Record

    Record(name => Str, age => Int)

Structural record type (plain hashrefs).
See also C<struct> (L<Typist>) for nominal records.

=head2 Literal

    Literal(42)

Literal type for a specific value.
Base type is inferred from the value.

=head2 Handler

    Handler(Console)

Effect handler type. C<Handler[E]> expands to a record of the effect's
operation signatures. Used to type handler values passed to C<handle>.

=head2 optional

    optional(email => Str)

Mark a struct or record field as optional (may be omitted at construction).
Returns a C<("field?", Type)> pair that is flattened into the field list.
Use positionally in C<struct> definitions, not as a value for a key:

    struct Person => (name => Str, age => Int, optional(email => Str));

=head1 TYPE VARIABLE CONSTANTS

Importable via C<use Typist::DSL qw(T U V)> or the C<:vars> tag.
Each is a L<Typist::Type::Var> instance.

=head2 T

Type variable C<T>.

=head2 U

Type variable C<U>.

=head2 V

Type variable C<V>.

=head2 A

Type variable C<A>.

=head2 B

Type variable C<B>.

=head2 K

Type variable C<K>.

=head1 INTERNAL CONSTRUCTORS

Importable via the C<:internal> tag.
For building type expressions programmatically.

=head2 TVar

    TVar('T', bound => Num)

Create a type variable with optional bounds or kind.

=head2 Alias

    Alias('MyType')

Create a type alias reference. Resolved lazily via the registry.

=head2 Row

    Row(IO => 1, Exn => 1)

Create an effect row type.

=head2 Eff

    Eff(Row(IO => 1))

Wrap a row type into an effect type.

=head2 Func

    Func(Int, Str, returns => Bool)

Create a function type. Requires C<returns =E<gt> Type>.

=head2 export_map

    my $map = Typist::DSL->export_map;

Returns a hashref mapping all exported names to coderefs.
Covers both C<@EXPORT> and C<@EXPORT_OK>.

=head1 TYPE OPERATORS

Provided by L<Typist::Type> overloading (available on all type objects):

    Int | Str            # Union
    Readable & Writable  # Intersection
    "$type"              # Stringify

=head1 SEE ALSO

L<Typist>, F<docs/type-system.md>

=cut
