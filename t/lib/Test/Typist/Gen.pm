package Test::Typist::Gen;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Literal;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Param;
use Typist::Type::Var;

use Exporter 'import';
our @EXPORT_OK = qw(
    gen_atom gen_literal gen_ground_type gen_type gen_subtype_pair
);

# ── Atom hierarchy ───────────────────────────────

my @CONCRETE_ATOMS = qw(Bool Int Double Num Str Undef);
my @ALL_ATOMS      = (@CONCRETE_ATOMS, 'Any');

my %PARENT = (
    Bool   => 'Int',
    Int    => 'Double',
    Double => 'Num',
    Num    => 'Any',
    Str    => 'Any',
    Undef  => 'Any',
);

# Transitive ancestor chains (excluding self)
my %ANCESTORS;
for my $atom (@ALL_ATOMS) {
    my @chain;
    my $cur = $atom;
    while (my $p = $PARENT{$cur}) {
        push @chain, $p;
        $cur = $p;
    }
    $ANCESTORS{$atom} = \@chain;
}

# ── Primitive generators ─────────────────────────

sub gen_atom () {
    Typist::Type::Atom->new($CONCRETE_ATOMS[int rand @CONCRETE_ATOMS]);
}

my @LIT_POOL = (
    [0,       'Int'],
    [1,       'Int'],
    [42,      'Int'],
    [-7,      'Int'],
    [3.14,    'Double'],
    [0.0,     'Double'],
    ['hello', 'Str'],
    ['',      'Str'],
    ['world', 'Str'],
);

sub gen_literal () {
    my $entry = $LIT_POOL[int rand @LIT_POOL];
    Typist::Type::Literal->new($entry->[0], $entry->[1]);
}

# ── Composite generators ────────────────────────

sub gen_ground_type (%opts) {
    my $max_depth = $opts{max_depth} // 3;
    _gen_ground($max_depth);
}

sub gen_type (%opts) {
    my $max_depth = $opts{max_depth} // 3;
    _gen_with_vars($max_depth);
}

# Generate (sub, super) pair where sub <: super is guaranteed.
sub gen_subtype_pair () {
    my $r = rand();

    if ($r < 0.3) {
        # Literal <: base atom
        my $lit = gen_literal();
        my $base = Typist::Type::Atom->new($lit->base_type);
        return ($lit, $base);
    }
    elsif ($r < 0.6) {
        # Atom chain: pick atom, pick ancestor
        my $atom_name = $CONCRETE_ATOMS[int rand @CONCRETE_ATOMS];
        my $ancestors = $ANCESTORS{$atom_name};
        if (@$ancestors) {
            my $super_name = $ancestors->[int rand @$ancestors];
            return (
                Typist::Type::Atom->new($atom_name),
                Typist::Type::Atom->new($super_name),
            );
        }
        # Fallback: T <: Any
        return (
            Typist::Type::Atom->new($atom_name),
            Typist::Type::Atom->new('Any'),
        );
    }
    else {
        # T <: T|U (union introduction)
        my $t = gen_atom();
        my $u = gen_atom();
        return ($t, Typist::Type::Union->new($t, $u));
    }
}

# ── Internal generators ─────────────────────────

sub _gen_ground ($depth) {
    if ($depth <= 0) {
        return (rand() < 0.15) ? gen_literal() : gen_atom();
    }

    my $r = rand();

    if ($r < 0.40) {
        # Atom
        gen_atom();
    }
    elsif ($r < 0.55) {
        # Union of 2
        Typist::Type::Union->new(
            _gen_ground($depth - 1),
            _gen_ground($depth - 1),
        );
    }
    elsif ($r < 0.70) {
        # Func
        my $nparams = int(rand(3));
        my @params = map { _gen_ground($depth - 1) } 1 .. $nparams;
        my $ret = _gen_ground($depth - 1);
        Typist::Type::Func->new(\@params, $ret);
    }
    elsif ($r < 0.85) {
        # Param (ArrayRef[T] or HashRef[K,V])
        if (rand() < 0.6) {
            Typist::Type::Param->new('ArrayRef', _gen_ground($depth - 1));
        } else {
            Typist::Type::Param->new('HashRef',
                Typist::Type::Atom->new('Str'),
                _gen_ground($depth - 1),
            );
        }
    }
    elsif ($r < 0.95) {
        # Intersection of 2
        Typist::Type::Intersection->new(
            _gen_ground($depth - 1),
            _gen_ground($depth - 1),
        );
    }
    else {
        # Literal
        gen_literal();
    }
}

my @VAR_NAMES = ('T', 'U', 'V', 'W');

sub _gen_with_vars ($depth) {
    if ($depth <= 0) {
        return (rand() < 0.2)
            ? Typist::Type::Var->new($VAR_NAMES[int rand @VAR_NAMES])
            : _gen_ground(0);
    }

    my $r = rand();
    if ($r < 0.15) {
        Typist::Type::Var->new($VAR_NAMES[int rand @VAR_NAMES]);
    } else {
        _gen_ground($depth);
    }
}

1;
