package Typist::Type::Eff;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';

# Effect annotation wrapper: Eff(Console | State | r)
# A thin delegation layer over Type::Row.
# contains() always returns 1 — effects are phantom types.

sub new ($class, $row) {
    bless +{ row => $row }, $class;
}

sub row    ($self) { $self->{row} }
sub is_eff ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    'Eff(' . $self->{row}->to_string . ')';
}

sub equals ($self, $other) {
    return 0 unless $other->is_eff;
    $self->{row}->equals($other->row);
}

sub contains ($self, $) { 1 }

sub free_vars ($self) { $self->{row}->free_vars }

sub substitute ($self, $bindings) {
    my $new_row = $self->{row}->substitute($bindings);
    $new_row->equals($self->{row}) ? $self : __PACKAGE__->new($new_row);
}

1;

=head1 NAME

Typist::Type::Eff - Effect annotation wrapper (Eff(Console | State))

=head1 SYNOPSIS

    use Typist::Type::Eff;

    my $eff = Typist::Type::Eff->new($row);

=head1 DESCRIPTION

A thin delegation layer over L<Typist::Type::Row>. Wraps a row type
to represent function effect annotations (C<! Eff(Console | State)>).
Effects are phantom types: C<contains> always returns true.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_eff> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 row

    my $row = $eff->row;

Returns the underlying L<Typist::Type::Row>.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Row>, L<Typist::Effect>

=cut
