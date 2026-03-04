package Typist::KindChecker;
use v5.40;

our $VERSION = '0.01';

use Typist::Kind;

# Built-in type constructor kind table.
my %CONSTRUCTOR_KINDS;

sub _init_kinds {
    return if %CONSTRUCTOR_KINDS;
    my $star = Typist::Kind->Star;
    %CONSTRUCTOR_KINDS = (
        # ArrayRef : * -> *
        ArrayRef => Typist::Kind->Arrow($star, $star),
        # HashRef : * -> * -> *
        HashRef  => Typist::Kind->Arrow($star, Typist::Kind->Arrow($star, $star)),
        # Tuple : variadic, handled specially
        # Ref : * -> *
        Ref      => Typist::Kind->Arrow($star, $star),
        # Maybe : * -> *  (desugars to union, but kind is still * -> *)
        Maybe    => Typist::Kind->Arrow($star, $star),
    );
}

# ── Public API ──────────────────────────────────

# Look up the kind of a type constructor by name.
sub constructor_kind ($class, $name) {
    _init_kinds();
    $CONSTRUCTOR_KINDS{$name};
}

# Reset kinds to built-in defaults (for test isolation).
sub reset_kinds ($class) {
    %CONSTRUCTOR_KINDS = ();
    _init_kinds();
}

# Register a custom type constructor kind.
sub register_kind ($class, $name, $kind) {
    _init_kinds();
    $CONSTRUCTOR_KINDS{$name} = $kind;
}

# Check that a type application F[A, B, ...] is kind-correct.
# Returns the resulting kind, or dies on mismatch.
sub check_application ($class, $constructor_name, @arg_kinds) {
    _init_kinds();

    my $kind = $CONSTRUCTOR_KINDS{$constructor_name}
        // return Typist::Kind->Star;  # Unknown constructors assumed *

    for my $i (0 .. $#arg_kinds) {
        unless (ref $kind eq 'Typist::Kind::Arrow') {
            my $excess = scalar(@arg_kinds) - $i;
            die "KindChecker: $constructor_name applied to too many type arguments"
                . " ($excess excess)\n";
        }

        unless ($kind->from->equals($arg_kinds[$i])) {
            die sprintf(
                "KindChecker: %s argument %d has kind %s, expected %s\n",
                $constructor_name, $i + 1,
                $arg_kinds[$i]->to_string, $kind->from->to_string,
            );
        }

        $kind = $kind->to;
    }

    $kind;
}

# Infer the kind of a type expression.
sub infer_kind ($class, $type, $var_kinds = undef) {
    $var_kinds //= +{};
    _init_kinds();

    if ($type->is_atom) {
        return Typist::Kind->Star;
    }

    if ($type->is_var) {
        return $var_kinds->{$type->name} // Typist::Kind->Star;
    }

    if ($type->is_literal || $type->is_newtype) {
        return Typist::Kind->Star;
    }

    if ($type->is_row || $type->is_eff) {
        return Typist::Kind->Row;
    }

    if ($type->is_param) {
        my @param_kinds = map { $class->infer_kind($_, $var_kinds) } $type->params;

        # Type variable application: F[T] where F is a Var with higher kind.
        if ($type->has_var_base) {
            my $var_name = $type->base->name;
            my $var_kind = $var_kinds->{$var_name}
                // return Typist::Kind->Star;  # Unknown var assumed *

            my $kind = $var_kind;
            for my $i (0 .. $#param_kinds) {
                unless (ref $kind eq 'Typist::Kind::Arrow') {
                    my $excess = scalar(@param_kinds) - $i;
                    die "KindChecker: type variable $var_name applied to too many"
                        . " type arguments ($excess excess)\n";
                }
                unless ($kind->from->equals($param_kinds[$i])) {
                    die sprintf(
                        "KindChecker: %s argument %d has kind %s, expected %s\n",
                        $var_name, $i + 1,
                        $param_kinds[$i]->to_string, $kind->from->to_string,
                    );
                }
                $kind = $kind->to;
            }
            return $kind;
        }

        return $class->check_application($type->base, @param_kinds);
    }

    if ($type->is_func) {
        # CodeRef is always *
        return Typist::Kind->Star;
    }

    if ($type->is_union || $type->is_intersection) {
        # All members must be *
        for my $m ($type->members) {
            my $k = $class->infer_kind($m, $var_kinds);
            unless ($k->equals(Typist::Kind->Star)) {
                die "KindChecker: union/intersection member has kind "
                    . $k->to_string . ", expected *\n";
            }
        }
        return Typist::Kind->Star;
    }

    if ($type->is_record) {
        return Typist::Kind->Star;
    }

    if ($type->is_alias) {
        # Aliases resolve to *, unless they refer to a type constructor
        return $CONSTRUCTOR_KINDS{$type->alias_name} // Typist::Kind->Star;
    }

    Typist::Kind->Star;
}

1;

=head1 NAME

Typist::KindChecker - Kind checking and inference for type expressions

=head1 SYNOPSIS

    use Typist::KindChecker;

    my $k = Typist::KindChecker->constructor_kind('ArrayRef');  # * -> *
    my $result = Typist::KindChecker->check_application('ArrayRef', $star);
    my $kind = Typist::KindChecker->infer_kind($type, \%var_kinds);

=head1 DESCRIPTION

Validates kind-correctness of type applications (e.g., C<ArrayRef[Int]>)
and infers kinds of type expressions. Maintains a registry of built-in
type constructor kinds (C<ArrayRef>, C<HashRef>, C<Maybe>, C<Ref>).

=head1 METHODS

=head2 constructor_kind

    my $kind = Typist::KindChecker->constructor_kind($name);

Returns the kind of a named type constructor, or C<undef> if unknown.

=head2 register_kind

    Typist::KindChecker->register_kind($name, $kind);

Registers a custom type constructor kind.

=head2 check_application

    my $result_kind = Typist::KindChecker->check_application($name, @arg_kinds);

Checks that a type application C<F[A, B, ...]> is kind-correct. Returns
the resulting kind. Dies on kind mismatch or excess arguments.

=head2 infer_kind

    my $kind = Typist::KindChecker->infer_kind($type, \%var_kinds);

Infers the kind of a type expression. C<%var_kinds> maps type variable
names to their kinds (defaults to C<*>).

=head1 SEE ALSO

L<Typist::Kind>, L<Typist::Static::Checker>

=cut
