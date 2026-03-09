package Typist::EffectScope;
use v5.40;

our $VERSION = '0.01';

# Capability token for scoped effect dispatch.
# Each EffectScope has a unique identity — handler lookup is by scope ID,
# not by effect name. This enables multiple independent instances of
# the same effect type (e.g., two separate State[Int] counters).
#
# Per-effect subclasses are created dynamically by scoped().
# Operation methods on the subclass dispatch through the scoped handler stack.

my $_next_id = 0;

sub new ($class, %args) {
    bless +{
        _scope_id   => ++$_next_id,
        effect_name => $args{effect_name} // die("EffectScope requires effect_name\n"),
        base_name   => $args{base_name}   // die("EffectScope requires base_name\n"),
    }, $class;
}

sub _scope_id   ($self) { $self->{_scope_id} }
sub effect_name ($self) { $self->{effect_name} }
sub base_name   ($self) { $self->{base_name} }

1;

=head1 NAME

Typist::EffectScope - Capability token for scoped algebraic effects

=head1 SYNOPSIS

    use Typist;

    effect 'State[S]' => +{
        get => '() -> S',
        put => '(S) -> Void',
    };

    my $counter = scoped 'State[Int]';

    handle {
        $counter->put(0);
        $counter->put($counter->get() + 1);
        $counter->get();  # => 1
    } $counter => +{
        get => sub { ... },
        put => sub { ... },
    };

=head1 DESCRIPTION

C<Typist::EffectScope> is the base class for scoped effect capability tokens.
Each token has a unique identity (C<_scope_id>). When used with C<handle>,
the handler is bound to that specific token rather than to the effect name,
enabling multiple independent instances of the same effect.

Per-effect subclasses (e.g., C<Typist::EffectScope::State>) are created
dynamically by C<scoped()>. Each subclass has methods corresponding
to the effect's operations, which dispatch through the scoped handler stack.

=head1 SEE ALSO

L<Typist>, L<Typist::Handler>, L<Typist::Effect>

=cut
