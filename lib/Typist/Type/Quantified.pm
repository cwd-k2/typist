package Typist::Type::Quantified;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use List::Util 'all';

# Universally quantified type: forall A B. (A -> B) -> ArrayRef[A] -> ArrayRef[B]
# vars: [{name => 'A'}, {name => 'B', bound => NumType}]
# body: the quantified type (typically Func)

sub new ($class, %opts) {
    bless +{
        vars => $opts{vars},
        body => $opts{body},
    }, $class;
}

sub vars         ($self) { $self->{vars}->@* }
sub body         ($self) { $self->{body} }
sub is_quantified ($self) { 1 }

sub name ($self) { 'Quantified' }

sub to_string ($self) {
    my @var_strs = map {
        $_->{bound} ? "$_->{name}: " . $_->{bound}->to_string : $_->{name}
    } $self->{vars}->@*;
    'forall ' . join(' ', @var_strs) . '. ' . $self->{body}->to_string;
}

sub equals ($self, $other) {
    return 0 unless $other->isa(__PACKAGE__);
    my @sv = $self->{vars}->@*;
    my @ov = $other->vars;
    return 0 unless @sv == @ov;
    for my $i (0 .. $#sv) {
        return 0 unless $sv[$i]{name} eq $ov[$i]{name};
        my $sb = $sv[$i]{bound};
        my $ob = $ov[$i]{bound};
        return 0 if !$sb != !$ob;
        return 0 if $sb && !$sb->equals($ob);
    }
    $self->{body}->equals($other->body);
}

sub contains ($self, $value) {
    $self->{body}->contains($value);
}

sub free_vars ($self) {
    my %bound = map { $_->{name} => 1 } $self->{vars}->@*;
    grep { !$bound{$_} } $self->{body}->free_vars;
}

sub substitute ($self, $bindings) {
    my %bound = map { $_->{name} => 1 } $self->{vars}->@*;
    # Filter out bound variables from bindings to avoid capture
    my %filtered = map { $_ => $bindings->{$_} }
                   grep { !$bound{$_} }
                   keys %$bindings;

    my @new_vars = map {
        $_->{bound}
            ? +{ name => $_->{name}, bound => $_->{bound}->substitute(\%filtered) }
            : +{ %$_ }
    } $self->{vars}->@*;

    __PACKAGE__->new(
        vars => \@new_vars,
        body => $self->{body}->substitute(\%filtered),
    );
}

1;
