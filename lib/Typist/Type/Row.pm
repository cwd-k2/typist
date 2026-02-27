package Typist::Type::Row;
use v5.40;
use parent 'Typist::Type';
use List::Util 'uniq', 'all';

# Effect row type: an ordered set of effect labels with an optional tail variable.
#   { labels => ['Console', 'State'], row_var => 'r' }
#
# Labels are sorted and deduplicated at construction (Union normalization pattern).
# A closed row has no row_var; an open row carries a tail variable for polymorphism.
# contains() always returns 1 — rows are phantom types.

sub new ($class, %args) {
    my @labels = sort(uniq(($args{labels} // [])->@*));
    bless +{
        labels  => \@labels,
        row_var => $args{row_var},
    }, $class;
}

sub labels  ($self) { $self->{labels}->@* }
sub row_var ($self) { $self->{row_var} }
sub is_row  ($self) { 1 }

sub is_closed ($self) { !defined $self->{row_var} }
sub is_empty  ($self) { !@{$self->{labels}} && !defined $self->{row_var} }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    my @parts = $self->{labels}->@*;
    push @parts, $self->{row_var} if defined $self->{row_var};
    join ' | ', @parts;
}

sub equals ($self, $other) {
    return 0 unless $other->is_row;

    my @sl = $self->{labels}->@*;
    my @ol = $other->labels;
    return 0 unless @sl == @ol;
    return 0 unless all { $sl[$_] eq $ol[$_] } 0 .. $#sl;

    my $sv = $self->{row_var}  // '';
    my $ov = $other->row_var // '';
    $sv eq $ov;
}

# Phantom — always validates
sub contains ($self, $) { 1 }

sub free_vars ($self) {
    defined $self->{row_var} ? ($self->{row_var}) : ();
}

sub substitute ($self, $bindings) {
    my $var = $self->{row_var};
    return $self unless defined $var && exists $bindings->{$var};

    my $bound = $bindings->{$var};

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
