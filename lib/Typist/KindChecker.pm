package Typist::KindChecker;
use v5.40;

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

    if ($type->is_param) {
        my @param_kinds = map { $class->infer_kind($_, $var_kinds) } $type->params;
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

    if ($type->is_struct) {
        return Typist::Kind->Star;
    }

    if ($type->is_alias) {
        # Aliases resolve to *, unless they refer to a type constructor
        return $CONSTRUCTOR_KINDS{$type->alias_name} // Typist::Kind->Star;
    }

    Typist::Kind->Star;
}

1;
