package Typist::Type::Func;
use v5.40;
use parent 'Typist::Type';
use List::Util 'all';

# Function type: CodeRef[Arg1, Arg2, ... -> Return]

sub new ($class, $params, $returns) {
    bless { params => $params, returns => $returns }, $class;
}

sub params  ($self) { $self->{params}->@* }
sub returns ($self) { $self->{returns} }
sub is_func ($self) { 1 }

sub name ($self) { 'CodeRef' }

sub to_string ($self) {
    my $args = join ', ', map { $_->to_string } $self->{params}->@*;
    my $ret  = $self->{returns}->to_string;
    "CodeRef[$args -> $ret]";
}

sub equals ($self, $other) {
    return 0 unless $other->is_func;

    my @sp = $self->{params}->@*;
    my @op = $other->params;
    return 0 unless @sp == @op;

    (all { $sp[$_]->equals($op[$_]) } 0 .. $#sp)
        && $self->{returns}->equals($other->returns);
}

sub contains ($self, $value) {
    defined $value && ref $value eq 'CODE';
}

sub free_vars ($self) {
    (map { $_->free_vars } $self->{params}->@*),
    $self->{returns}->free_vars;
}

sub substitute ($self, $bindings) {
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    my $new_ret    = $self->{returns}->substitute($bindings);
    __PACKAGE__->new(\@new_params, $new_ret);
}

1;
