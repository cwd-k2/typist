package Typist::Type::Func;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use List::Util 'all';

# Function type: CodeRef[Arg1, Arg2, ... -> Return ! Effects]
# effects is a Row object (optional, undef = pure)
# variadic: when true, last param is rest element type (accepts 0+ args)

sub new ($class, $params, $returns, $effects = undef, %opts) {
    bless +{
        params   => $params,
        returns  => $returns,
        effects  => $effects,
        variadic => $opts{variadic} ? 1 : 0,
    }, $class;
}

sub params   ($self) { $self->{params}->@* }
sub returns  ($self) { $self->{returns} }
sub effects  ($self) { $self->{effects} }
sub variadic ($self) { $self->{variadic} }
sub is_func  ($self) { 1 }

sub name ($self) { 'CodeRef' }

sub to_string ($self) {
    my @params = $self->{params}->@*;
    my @strs;
    for my $i (0 .. $#params) {
        my $s = $params[$i]->to_string;
        $s = "...$s" if $self->{variadic} && $i == $#params;
        push @strs, $s;
    }
    my $args = join ', ', @strs;
    my $ret  = $self->{returns}->to_string;
    my $str  = "($args) -> $ret";
    if ($self->{effects}) {
        $str .= ' ![' . $self->{effects}->to_string . ']';
    }
    $str;
}

sub equals ($self, $other) {
    return 0 unless $other->is_func;
    return 0 unless $self->{variadic} == $other->variadic;

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
    my @fv;
    push @fv, map { $_->free_vars } $self->{params}->@*;
    push @fv, $self->{returns}->free_vars;
    push @fv, $self->{effects}->free_vars if $self->{effects};
    @fv;
}

sub substitute ($self, $bindings) {
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    my $new_ret    = $self->{returns}->substitute($bindings);
    my $new_eff    = $self->{effects} ? $self->{effects}->substitute($bindings) : undef;
    __PACKAGE__->new(\@new_params, $new_ret, $new_eff, variadic => $self->{variadic});
}

1;

=head1 NAME

Typist::Type::Func - Function type ((Int, Str) -> Bool ![IO])

=head1 SYNOPSIS

    use Typist::Type::Func;

    my $fn = Typist::Type::Func->new(
        [$int_type, $str_type], $bool_type, $row, variadic => 0,
    );

=head1 DESCRIPTION

Represents a function type with parameter types, a return type, optional
effect annotation (a L<Typist::Type::Row>), and a variadic flag. When
variadic, the last parameter is the rest-element type accepting zero or
more arguments.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_func> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 params

    my @params = $func->params;

=head2 returns

    my $ret = $func->returns;

=head2 effects

    my $row = $func->effects;

Returns the effect row, or C<undef> for pure functions.

=head2 variadic

    my $bool = $func->variadic;

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Eff>

=cut
