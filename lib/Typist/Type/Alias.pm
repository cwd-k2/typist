package Typist::Type::Alias;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';

# Named alias — resolves lazily against Registry on first access.

sub new ($class, $name, %opts) {
    bless +{ name => $name, resolved => undef, registry => $opts{registry} }, $class;
}

sub alias_name ($self) { $self->{name} }
sub is_alias   ($self) { 1 }

sub _resolve ($self) {
    unless ($self->{resolved}) {
        my $reg = $self->{registry};
        if ($reg) {
            $self->{resolved} = $reg->lookup_type($self->{name});
        } else {
            require Typist::Registry;
            $self->{resolved} = Typist::Registry->lookup_type($self->{name});
        }
    }
    $self->{resolved};
}

sub name ($self) { $self->{name} }

sub to_string ($self) { $self->{name} }

sub equals ($self, $other) {
    return 1 if $other->is_alias && $self->{name} eq $other->alias_name;
    if (my $r = $self->_resolve) {
        return $r->equals($other);
    }
    0;
}

# ── Cycle Detection Guards ─────────────────────

my $MAX_CONTAINS_DEPTH = 50;
my %_contains_depth;
my %_free_vars_guard;
my %_substitute_guard;

sub contains ($self, $value) {
    my $r = $self->_resolve // return 0;
    my $name = $self->{name};
    $_contains_depth{$name} //= 0;
    return 0 if $_contains_depth{$name} >= $MAX_CONTAINS_DEPTH;
    local $_contains_depth{$name} = $_contains_depth{$name} + 1;
    $r->contains($value);
}

sub free_vars ($self) {
    my $r = $self->_resolve // return ();
    my $name = $self->{name};
    return () if $_free_vars_guard{$name};
    local $_free_vars_guard{$name} = 1;
    $r->free_vars;
}

sub substitute ($self, $bindings) {
    my $r = $self->_resolve // return $self;
    my $name = $self->{name};
    return $self if $_substitute_guard{$name};
    local $_substitute_guard{$name} = 1;
    $r->substitute($bindings);
}

1;

=head1 NAME

Typist::Type::Alias - Named type alias with lazy resolution

=head1 SYNOPSIS

    use Typist::Type::Alias;

    my $alias = Typist::Type::Alias->new('UserId');
    # Resolves lazily against Typist::Registry

=head1 DESCRIPTION

A named reference to a type defined via C<typedef>. Resolves lazily
against the L<Typist::Registry> on first access, with cycle detection
guards on C<contains>, C<free_vars>, and C<substitute>.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_alias> (returns 1),
C<alias_name>, C<name>, C<to_string>, C<equals>, C<contains>,
C<free_vars>, C<substitute>.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Registry>

=cut
