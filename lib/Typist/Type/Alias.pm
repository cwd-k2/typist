package Typist::Type::Alias;
use v5.40;
use parent 'Typist::Type';

# Named alias — resolves lazily against Registry on first access.

sub new ($class, $name) {
    bless +{ name => $name, resolved => undef }, $class;
}

sub alias_name ($self) { $self->{name} }
sub is_alias   ($self) { 1 }

sub _resolve ($self) {
    unless ($self->{resolved}) {
        require Typist::Registry;
        $self->{resolved} = Typist::Registry->lookup_type($self->{name});
    }
    $self->{resolved};
}

sub name ($self) { $self->{name} }

sub to_string ($self) { $self->{name} }

sub equals ($self, $other) {
    if ($other->is_alias) {
        return 1 if $self->{name} eq $other->alias_name;
    }
    if (my $r = $self->_resolve) {
        return $r->equals($other);
    }
    0;
}

my $MAX_DEPTH = 50;
my %_contains_depth;

sub contains ($self, $value) {
    my $r = $self->_resolve
        // die "Typist: unresolved alias '$self->{name}'";

    my $name = $self->{name};
    $_contains_depth{$name} //= 0;
    if ($_contains_depth{$name} >= $MAX_DEPTH) {
        return 0;
    }

    $_contains_depth{$name}++;
    my $ok = eval { $r->contains($value) };
    my $err = $@;
    $_contains_depth{$name}--;
    die $err if $err;
    $ok;
}

sub free_vars ($self) {
    my $r = $self->_resolve // return ();
    $r->free_vars;
}

sub substitute ($self, $bindings) {
    my $r = $self->_resolve // return $self;
    $r->substitute($bindings);
}

1;
