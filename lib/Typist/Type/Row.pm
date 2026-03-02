package Typist::Type::Row;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use List::Util 'uniq', 'all';
use Typist::Type::Var;

# Effect row type: an ordered set of effect labels with an optional tail variable.
#   { labels => ['Console', 'State'], row_var => Var('r') }
#
# Labels are sorted and deduplicated at construction (Union normalization pattern).
# A closed row has no row_var; an open row carries a tail variable for polymorphism.
# row_var is stored as a Typist::Type::Var (strings are normalized at construction).
# contains() always returns 1 — rows are phantom types.

sub new ($class, %args) {
    my @labels = sort(uniq(($args{labels} // [])->@*));
    my $rv = $args{row_var};
    $rv = Typist::Type::Var->new($rv) if defined $rv && !ref $rv;
    bless +{
        labels  => \@labels,
        row_var => $rv,
    }, $class;
}

sub labels  ($self) { $self->{labels}->@* }
sub row_var ($self) { $self->{row_var} }
sub is_row  ($self) { 1 }

# String name of the row variable (works both before and after Var normalization).
sub row_var_name ($self) {
    return undef unless defined $self->{row_var};
    ref $self->{row_var} ? $self->{row_var}->name : $self->{row_var};
}

sub is_closed ($self) { !defined $self->{row_var} }
sub is_empty  ($self) { !@{$self->{labels}} && !defined $self->{row_var} }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    my @parts = $self->{labels}->@*;
    push @parts, $self->{row_var}->name if defined $self->{row_var};
    join ' | ', @parts;
}

sub equals ($self, $other) {
    return 0 unless $other->is_row;

    my @sl = $self->{labels}->@*;
    my @ol = $other->labels;
    return 0 unless @sl == @ol;
    return 0 unless all { $sl[$_] eq $ol[$_] } 0 .. $#sl;

    my $sv = $self->row_var_name  // '';
    my $ov = $other->row_var_name // '';
    $sv eq $ov;
}

# Phantom — always validates
sub contains ($self, $) { 1 }

sub free_vars ($self) {
    defined $self->{row_var} ? ($self->{row_var}->name) : ();
}

sub substitute ($self, $bindings) {
    my $var = $self->{row_var};
    return $self unless defined $var;
    my $name = $var->name;
    return $self unless exists $bindings->{$name};

    my $bound = $bindings->{$name};

    # Binding is a Row — merge labels and inherit tail
    if ($bound->is_row) {
        my @merged = sort(uniq($self->{labels}->@*, $bound->labels));
        return __PACKAGE__->new(
            labels  => \@merged,
            row_var => $bound->row_var,
        );
    }

    # Non-row binding — just drop the row_var
    $self;
}

1;

=head1 NAME

Typist::Type::Row - Effect row type (Remy-style row polymorphism)

=head1 SYNOPSIS

    use Typist::Type::Row;

    my $row = Typist::Type::Row->new(
        labels  => ['Console', 'State'],
        row_var => 'r',
    );

=head1 DESCRIPTION

An ordered set of effect labels with an optional tail variable for
row polymorphism. Labels are sorted and deduplicated at construction.
A closed row has no C<row_var>; an open row carries a tail variable.

Rows are phantom types: C<contains> always returns true.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_row> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 labels

    my @labels = $row->labels;

=head2 row_var

    my $var = $row->row_var;  # Typist::Type::Var or undef

=head2 row_var_name

    my $name = $row->row_var_name;  # string or undef

=head2 is_closed / is_empty

    my $closed = $row->is_closed;
    my $empty  = $row->is_empty;

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Eff>

=cut
