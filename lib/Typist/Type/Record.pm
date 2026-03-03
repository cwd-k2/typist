package Typist::Type::Record;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use Scalar::Util qw(reftype blessed);
use List::Util   'all';

# Structural record type: { key => Type, key? => Type, ... }
# Optional fields are denoted by trailing '?' on the key name,
# or by wrapping the value with optional(Type) from the DSL.

sub new ($class, %all_fields) {
    my (%required, %optional);
    for my $key (keys %all_fields) {
        my $val = $all_fields{$key};
        if (blessed($val) && $val->isa('Typist::DSL::Optional')) {
            $optional{$key} = $val->inner;
        } elsif ($key =~ /\A(.+)\?\z/) {
            $optional{$1} = $val;
        } else {
            $required{$key} = $val;
        }
    }
    bless +{ required => \%required, optional => \%optional }, $class;
}

# Named constructor: bypass key? encoding when required/optional are pre-separated.
sub from_parts ($class, %parts) {
    bless +{
        required => $parts{required} // +{},
        optional => $parts{optional} // +{},
    }, $class;
}

sub fields ($self) {
    # Backward compat: return all fields (required + optional with '?' suffix)
    my %all;
    %all = %{$self->{required}};
    for my $key (keys %{$self->{optional}}) {
        $all{"${key}?"} = $self->{optional}{$key};
    }
    %all;
}

sub required_fields ($self) { %{$self->{required}} }
sub optional_fields ($self) { %{$self->{optional}} }
sub required_ref    ($self) { $self->{required} }
sub optional_ref    ($self) { $self->{optional} }
sub field_ref       ($self) { +{ $self->fields } }
sub is_record       ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    my @parts;
    for my $key (sort keys %{$self->{required}}) {
        push @parts, "$key => " . $self->{required}{$key}->to_string;
    }
    for my $key (sort keys %{$self->{optional}}) {
        push @parts, "${key}? => " . $self->{optional}{$key}->to_string;
    }
    "{ " . join(', ', @parts) . " }";
}

sub equals ($self, $other) {
    return 0 unless $other->is_record;

    my %sr = %{$self->{required}};
    my %so = %{$self->{optional}};
    my %or = $other->required_fields;
    my %oo = $other->optional_fields;

    # Same required keys
    my @srk = sort keys %sr;
    my @ork = sort keys %or;
    return 0 unless @srk == @ork;
    return 0 unless all { $srk[$_] eq $ork[$_] } 0 .. $#srk;
    return 0 unless all { $sr{$_}->equals($or{$_}) } @srk;

    # Same optional keys
    my @sok = sort keys %so;
    my @ook = sort keys %oo;
    return 0 unless @sok == @ook;
    return 0 unless all { $sok[$_] eq $ook[$_] } 0 .. $#sok;
    return 0 unless all { $so{$_}->equals($oo{$_}) } @sok;

    1;
}

sub contains ($self, $value) {
    return 0 unless defined $value && ref $value && reftype($value) eq 'HASH';
    # All required fields must be present and match
    return 0 unless all {
        exists $value->{$_} && $self->{required}{$_}->contains($value->{$_})
    } keys %{$self->{required}};
    # Optional fields: check type only if present
    return 0 unless all {
        !exists $value->{$_} || $self->{optional}{$_}->contains($value->{$_})
    } keys %{$self->{optional}};
    1;
}

sub free_vars ($self) {
    my @fv;
    push @fv, map { $_->free_vars } values %{$self->{required}};
    push @fv, map { $_->free_vars } values %{$self->{optional}};
    @fv;
}

sub substitute ($self, $bindings) {
    my %new_req = map { $_ => $self->{required}{$_}->substitute($bindings) }
                  keys %{$self->{required}};
    my %new_opt = map { $_ => $self->{optional}{$_}->substitute($bindings) }
                  keys %{$self->{optional}};
    __PACKAGE__->from_parts(required => \%new_req, optional => \%new_opt);
}

1;

=head1 NAME

Typist::Type::Record - Structural record type ({ key => Type, ... })

=head1 SYNOPSIS

    use Typist::Type::Record;

    my $rec = Typist::Type::Record->new(
        name => $str_type, 'age?' => $int_type,
    );

=head1 DESCRIPTION

A structural record type with required and optional fields. Optional
fields are denoted by trailing C<?> on the key name or by wrapping
with C<optional(Type)> from the DSL. Supports width subtyping: a
record with more fields is a subtype of one with fewer.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_record> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 required_fields / optional_fields

    my %req = $rec->required_fields;
    my %opt = $rec->optional_fields;

=head2 from_parts

    my $rec = Typist::Type::Record->from_parts(
        required => \%req, optional => \%opt,
    );

Named constructor that bypasses C<key?> encoding.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Struct>

=cut
