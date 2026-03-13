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
        name             => ($args{name}       // die("Effect requires name\n")),
        operations       => ($args{operations} // +{}),
        protocol         => $args{protocol},
        ambient          => $args{ambient} ? 1 : 0,
        type_params      => ($args{type_params} // []),
        type_param_specs => ($args{type_param_specs} // []),
        _parsed          => +{},
    }, $class;
}

sub type_params      ($self) { $self->{type_params}->@* }
sub type_param_specs ($self) { $self->{type_param_specs}->@* }
sub is_generic       ($self) { scalar $self->{type_params}->@* }

sub name         ($self) { $self->{name} }
sub operations   ($self) { $self->{operations}->%* }
sub protocol     ($self) { $self->{protocol} }
sub has_protocol ($self) { defined $self->{protocol} }
sub is_ambient   ($self) { $self->{ambient} }

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
    if ($@ && !$ENV{TYPIST_CHECK_QUIET}) {
        warn "Typist: failed to parse effect op '$name' type '$expr': $@";
    }
    $self->{_parsed}{$name} = $type;  # cache (undef on parse failure)
    $type;
}

1;

=head1 NAME

Typist::Effect - Effect definition structure

=head1 SYNOPSIS

    use Typist::Effect;

    my $eff = Typist::Effect->new(
        name       => 'Console',
        operations => +{
            readLine  => '() -> Str',
            writeLine => '(Str) -> Void',
        },
    );

    say $eff->name;                      # "Console"
    my @ops = $eff->op_names;            # ("readLine", "writeLine")
    my $type = $eff->get_op_type('readLine');  # Typist::Type::Func

=head1 DESCRIPTION

Represents an algebraic effect definition: a named bag of typed operations.
Operation signatures are stored as strings and lazily parsed to
L<Typist::Type> objects on first access via C<get_op_type>.

Defined via the C<effect> keyword exported by L<Typist>:

    effect Console => +{
        writeLine => '(Str) -> Void',
    };

=head1 METHODS

=head2 new

    my $eff = Typist::Effect->new(name => $name, operations => \%ops);

Creates a new effect definition. C<name> is required; C<operations>
defaults to an empty hashref.

=head2 name

    my $name = $eff->name;

Returns the effect name.

=head2 operations

    my %ops = $eff->operations;

Returns the operations hash (name => type-string pairs).

=head2 op_names

    my @names = $eff->op_names;

Returns sorted operation names.

=head2 get_op

    my $type_str = $eff->get_op($op_name);

Returns the raw type string for an operation.

=head2 get_op_type

    my $type = $eff->get_op_type($op_name);

Returns the parsed L<Typist::Type> object for an operation, lazily
parsing and caching the result. Returns C<undef> if not found or
parse fails.

=head1 SEE ALSO

L<Typist>, L<Typist::Handler>, L<Typist::Type::Eff>

=cut
