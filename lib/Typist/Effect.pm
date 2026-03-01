package Typist::Effect;
use v5.40;

our $VERSION = '0.01';

# Effect definition structure.
# Mirrors TypeClass::Def pattern: a named bag of typed operations.
#
#   { name => 'Console', operations => { readLine => '(Str) -> Void', ... } }
#
# Operation type strings are lazily parsed to Type objects on first access
# via get_op_type(). The raw strings are preserved for backward compatibility.

sub new ($class, %args) {
    bless +{
        name       => ($args{name}       // die("Effect requires name\n")),
        operations => ($args{operations} // +{}),
        _parsed    => +{},
    }, $class;
}

sub name       ($self) { $self->{name} }
sub operations ($self) { $self->{operations}->%* }

sub op_names ($self) { sort keys $self->{operations}->%* }

# Raw operation type string (backward compatible).
sub get_op ($self, $name) { $self->{operations}{$name} }

# Parsed operation type (Type object). Returns undef if not found or parse fails.
sub get_op_type ($self, $name) {
    return $self->{_parsed}{$name} if exists $self->{_parsed}{$name};

    my $expr = $self->{operations}{$name} // return undef;
    my $type = eval {
        require Typist::Parser;
        Typist::Parser->parse($expr);
    };
    $self->{_parsed}{$name} = $type;  # cache (undef on parse failure)
    $type;
}

1;
