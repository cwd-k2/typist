package Typist::Type::Func;
use v5.40;
use parent 'Typist::Type';
use List::Util 'all';

# Function type: CodeRef[Arg1, Arg2, ... -> Return ! Effects]
# effects is a Row object (optional, undef = pure)

sub new ($class, $params, $returns, $effects = undef) {
    bless +{ params => $params, returns => $returns, effects => $effects }, $class;
}

sub params  ($self) { $self->{params}->@* }
sub returns ($self) { $self->{returns} }
sub effects ($self) { $self->{effects} }
sub is_func ($self) { 1 }

sub name ($self) { 'CodeRef' }

sub to_string ($self) {
    my $args = join ', ', map { $_->to_string } $self->{params}->@*;
    my $ret  = $self->{returns}->to_string;
    my $str  = "($args) -> $ret";
    if ($self->{effects}) {
        $str .= ' !Eff(' . $self->{effects}->to_string . ')';
    }
    $str;
}

sub equals ($self, $other) {
    return 0 unless $other->is_func;

    my @sp = $self->{params}->@*;
    my @op = $other->params;
    return 0 unless @sp == @op;

    return 0 unless all { $sp[$_]->equals($op[$_]) } 0 .. $#sp;
    return 0 unless $self->{returns}->equals($other->returns);

    my $se = $self->{effects};
    my $oe = $other->effects;
    return 1 if !$se && !$oe;
    return 0 if !$se || !$oe;
    $se->equals($oe);
}

sub contains ($self, $value) {
    defined $value && ref $value eq 'CODE';
}

sub free_vars ($self) {
    (map { $_->free_vars } $self->{params}->@*),
    $self->{returns}->free_vars,
    ($self->{effects} ? $self->{effects}->free_vars : ());
}

sub substitute ($self, $bindings) {
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    my $new_ret    = $self->{returns}->substitute($bindings);
    my $new_eff    = $self->{effects} ? $self->{effects}->substitute($bindings) : undef;
    __PACKAGE__->new(\@new_params, $new_ret, $new_eff);
}

1;
