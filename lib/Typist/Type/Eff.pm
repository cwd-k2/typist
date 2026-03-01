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
