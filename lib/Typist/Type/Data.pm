package Typist::Type::Data;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use Scalar::Util 'blessed';

# Tagged union (algebraic data type):
#   datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';
#
# Parameterized:
#   datatype 'Option[T]' => Some => '(T)', None => '()';
#
# Variants are stored as { Tag => [Type, ...], ... }.
# Values are blessed into "Typist::Data::$name" with _tag, _values, and
# optional _type_args fields.

sub new ($class, $name, $variants, %opts) {
    bless +{
        name         => $name,
        variants     => $variants,
        type_params  => $opts{type_params}  // [],
        type_args    => $opts{type_args}    // [],   # concrete args for instantiated type
        return_types => $opts{return_types} // +{},  # GADT: { Tag => Type } per-constructor return
    }, $class;
}

sub name         ($self) { $self->{name} }
sub variants     ($self) { $self->{variants} }
sub type_params  ($self) { $self->{type_params}->@* }
sub type_args    ($self) { $self->{type_args}->@* }
sub return_types ($self) { $self->{return_types} }
sub is_data      ($self) { 1 }
sub is_gadt      ($self) { scalar keys $self->{return_types}->%* > 0 }

# Return type for a specific constructor tag.
# GADT: returns the explicit per-constructor type.
# Non-GADT: returns the generic Data[Var(P1), Var(P2), ...].
sub constructor_return_type ($self, $tag) {
    return $self->{return_types}{$tag} if exists $self->{return_types}{$tag};
    # Default: generic type with Var args
    if ($self->{type_params}->@*) {
        require Typist::Type::Var;
        my @params = map { Typist::Type::Var->new($_) } $self->{type_params}->@*;
        return __PACKAGE__->new($self->{name}, $self->{variants},
            type_params  => [$self->{type_params}->@*],
            type_args    => \@params,
            return_types => $self->{return_types},
        );
    }
    $self;
}

sub to_string ($self) {
    my $base = $self->{name};
    if ($self->{type_args}->@*) {
        $base .= '[' . join(', ', map { $_->to_string } $self->{type_args}->@*) . ']';
    } elsif ($self->{type_params}->@*) {
        $base .= '[' . join(', ', $self->{type_params}->@*) . ']';
    }
    # For display, just show the base name (not all variants)
    $base;
}

sub to_string_full ($self) {
    my @parts;
    for my $tag (sort keys $self->{variants}->%*) {
        my @types = $self->{variants}{$tag}->@*;
        my $part = @types
            ? "$tag(" . join(', ', map { $_->to_string } @types) . ")"
            : $tag;
        # GADT: show per-constructor return type
        if (exists $self->{return_types}{$tag}) {
            $part .= ' -> ' . $self->{return_types}{$tag}->to_string;
        }
        push @parts, $part;
    }
    my $variants = join ' | ', @parts;
    my $name = $self->to_string;
    "$name = $variants";
}

sub equals ($self, $other) {
    return 0 unless $other->is_data && $self->{name} eq $other->name;

    # Compare type_args if present
    my @sa = $self->{type_args}->@*;
    my @oa = $other->type_args;
    return 0 unless @sa == @oa;
    for my $i (0 .. $#sa) {
        return 0 unless $sa[$i]->equals($oa[$i]);
    }

    # Compare return_types (GADT)
    my $srt = $self->{return_types};
    my $ort = $other->return_types;
    my @sk = sort keys %$srt;
    my @ok = sort keys %$ort;
    return 0 unless @sk == @ok;
    for my $i (0 .. $#sk) {
        return 0 unless $sk[$i] eq $ok[$i];
        return 0 unless $srt->{$sk[$i]}->equals($ort->{$ok[$i]});
    }
    1;
}

sub contains ($self, $value) {
    return 0 unless defined $value && blessed($value);
    return 0 unless blessed($value) eq "Typist::Data::$self->{name}";
    my $tag = $value->{_tag};
    return 0 unless $tag && exists $self->{variants}{$tag};

    my @expected = $self->{variants}{$tag}->@*;
    my @actual   = ($value->{_values} // [])->@*;
    return 0 unless @actual == @expected;

    # If we have concrete type_args, substitute into expected types
    my %bindings;
    if ($self->{type_args}->@* && $self->{type_params}->@*) {
        %bindings = Typist::Type->_zip_type_bindings(
            $self->{type_params}, $self->{type_args},
        );
    }

    for my $i (0 .. $#expected) {
        my $exp = %bindings ? $expected[$i]->substitute(\%bindings) : $expected[$i];
        return 0 unless $exp->contains($actual[$i]);
    }
    1;
}

sub free_vars ($self) {
    my %seen;
    for my $types (values $self->{variants}->%*) {
        $seen{$_} = 1 for map { $_->free_vars } @$types;
    }
    for my $arg ($self->{type_args}->@*) {
        $seen{$_} = 1 for $arg->free_vars;
    }
    for my $rt (values $self->{return_types}->%*) {
        $seen{$_} = 1 for $rt->free_vars;
    }
    # Type params are bound by this declaration, not free
    delete $seen{$_} for $self->{type_params}->@*;
    keys %seen;
}

sub substitute ($self, $bindings) {
    my %new_variants;
    for my $tag (keys $self->{variants}->%*) {
        $new_variants{$tag} = [
            map { $_->substitute($bindings) } $self->{variants}{$tag}->@*
        ];
    }
    my @new_args = map { $_->substitute($bindings) } $self->{type_args}->@*;
    my %new_rt;
    for my $tag (keys $self->{return_types}->%*) {
        $new_rt{$tag} = $self->{return_types}{$tag}->substitute($bindings);
    }
    __PACKAGE__->new($self->{name}, \%new_variants,
        type_params  => [$self->{type_params}->@*],
        type_args    => \@new_args,
        return_types => \%new_rt,
    );
}

# Create an instantiated copy with concrete type arguments
sub instantiate ($self, @args) {
    __PACKAGE__->new($self->{name}, $self->{variants},
        type_params  => [$self->{type_params}->@*],
        type_args    => \@args,
        return_types => $self->{return_types},
    );
}

# Parse a constructor spec string into (param_types, return_type_expr).
# Normal ADT: '(Int, Str)' => ([Int, Str], undef)
# GADT:       '(Int) -> Expr[Int]' => ([Int], 'Expr[Int]')
sub parse_constructor_spec ($class, $spec, %opts) {
    return ([], undef) unless defined $spec && $spec =~ /\S/;

    my $inner = $spec;
    $inner =~ s/\A\(\s*//;

    # GADT: check for ') -> ReturnType' pattern
    my ($params_str, $return_expr);
    if ($inner =~ /\)\s*->\s*(.+)\z/) {
        $return_expr = $1;
        $inner =~ s/\)\s*->.*\z//;
        $params_str = $inner;
    } else {
        $inner =~ s/\s*\)\z//;
        $params_str = $inner;
    }

    require Typist::Parser;
    my @types;
    if ($params_str =~ /\S/) {
        @types = map { Typist::Parser->parse($_) } Typist::Parser->split_type_list($params_str);
    }

    # Alias→Var promotion for type parameter names
    if ($opts{type_params} && $opts{type_params}->@*) {
        require Typist::Type::Var;
        my %vn = map { $_ => 1 } $opts{type_params}->@*;
        @types = map {
            $_->is_alias && $vn{$_->alias_name}
                ? Typist::Type::Var->new($_->alias_name) : $_
        } @types;
    }

    return (\@types, $return_expr);
}

1;

=head1 NAME

Typist::Type::Data - Algebraic data type (tagged union / ADT / GADT)

=head1 SYNOPSIS

    use Typist::Type::Data;

    # Simple ADT
    my $shape = Typist::Type::Data->new('Shape', +{
        Circle    => [$int_type],
        Rectangle => [$int_type, $int_type],
    });

    # Parameterized ADT
    my $option = Typist::Type::Data->new('Option', +{
        Some => [$var_t], None => [],
    }, type_params => ['T']);

=head1 DESCRIPTION

Represents algebraic data types (tagged unions). Supports simple ADTs,
parameterized ADTs (C<Option[T]>), and GADTs (per-constructor return
types). Values are blessed into C<Typist::Data::$name> with C<_tag>,
C<_values>, and optional C<_type_args> fields.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_data> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 variants

    my $variants = $data->variants;  # { Tag => [\@types], ... }

=head2 type_params / type_args

    my @params = $data->type_params;  # ['T']
    my @args   = $data->type_args;    # [Atom('Int')]

=head2 is_gadt

    my $bool = $data->is_gadt;

True if any constructor has an explicit return type.

=head2 constructor_return_type

    my $type = $data->constructor_return_type($tag);

Returns the return type for a specific constructor.

=head2 instantiate

    my $concrete = $data->instantiate(@type_args);

Returns an instantiated copy with concrete type arguments.

=head2 parse_constructor_spec

    my ($types, $return_expr) = Typist::Type::Data->parse_constructor_spec(
        $spec, type_params => \@params,
    );

Shared parser for constructor spec strings.

=head1 SEE ALSO

L<Typist::Type>, L<Typist>

=cut
