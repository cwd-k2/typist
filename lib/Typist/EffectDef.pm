package Typist::EffectDef;
use v5.40;

our $VERSION = '0.01';

# Effect, handle, and protocol definitions.
# Extracted from Typist.pm for module decomposition.

# ── Protocol Support ────────────────────────────

sub _make_protocol (@args) {
    if (@args == 2 && !ref $args[0] && !ref $args[1]) {
        # protocol('(Str) -> Void', '* -> Connected')
        my ($sig, $trans) = @args;
        my ($lhs, $rhs) = $trans =~ /^\s*(.+?)\s*->\s*(.+?)\s*$/;
        die "Invalid protocol transition: '$trans'\n" unless defined $lhs;
        my @from = sort map { s/\s+//gr } split(/\s*\|\s*/, $lhs);
        my @to   = sort map { s/\s+//gr } split(/\s*\|\s*/, $rhs);
        return +{ __protocol__ => 1, sig => $sig, from => \@from, to => \@to };
    }
    die "Invalid protocol() call\n";
}

# ── Effect Support ──────────────────────────────

sub _effect ($name, @rest) {
    # Pop the operations hashref (always last argument)
    my $operations_ref = pop @rest;
    # Remaining strings are states (empty for protocol-less effects)
    my $states = @rest ? \@rest : undef;

    # Parse parameterized name: 'State[S]' → ('State', 'S')
    my ($base_name, @type_params);
    if ($name =~ /\A(\w+)\[(.+)\]\z/) {
        $base_name = $1;
        @type_params = map { /\A(\w+)/ ? $1 : $_ } split /\s*,\s*/, $2;
    } else {
        $base_name = $name;
    }

    # Process operation values: string or protocol('sig', 'transition') hashref
    my (%ops, %transitions, %op_map);
    for my $op_name (keys %$operations_ref) {
        my $val = $operations_ref->{$op_name};
        if (ref $val eq 'HASH' && $val->{__protocol__}) {
            $ops{$op_name} = $val->{sig};
            $op_map{$op_name} = { from => $val->{from}, to => $val->{to} };
            for my $f ($val->{from}->@*) {
                $transitions{$f}{$op_name} = $val->{to}[0];
            }
        } else {
            $ops{$op_name} = $val;
        }
    }

    my $protocol;
    if (%transitions) {
        require Typist::Protocol;
        $protocol = Typist::Protocol->new(
            transitions => +{%transitions},
            op_map      => +{%op_map},
            ($states ? (states => $states) : ()),
        );
    }

    my $eff = Typist::Effect->new(
        name        => $base_name,
        operations  => \%ops,
        type_params => \@type_params,
        protocol    => $protocol,
    );
    Typist::Registry->register_effect($base_name, $eff);

    # Install qualified subs for direct effect operation calls
    for my $op_name (keys %ops) {
        my ($eff_name, $op) = ($base_name, $op_name);
        no strict 'refs';
        *{"${eff_name}::${op}"} = sub (@args) {
            my $handler = Typist::Handler->find_handler($eff_name)
                // die "No handler for effect ${eff_name}::${op}\n";
            my $impl = $handler->{$op}
                // die "No handler for effect ${eff_name}::${op}\n";
            $impl->(@args);
        };
    }
}

# ── Scoped Effect Support (capability token) ────

sub _scoped ($name) {
    require Typist::EffectScope;

    my ($base_name) = $name =~ /\A(\w+)/;
    my $eff = Typist::Registry->lookup_effect($base_name)
        // die "Unknown effect: $base_name\n";

    # Create per-effect subclass dynamically (once per base effect)
    my $class = "Typist::EffectScope::${base_name}";
    unless ($class->can('_scope_id')) {
        no strict 'refs';
        @{"${class}::ISA"} = ('Typist::EffectScope');
        for my $op_name ($eff->op_names) {
            my $op = $op_name;
            *{"${class}::${op}"} = sub ($self, @args) {
                my $handler = Typist::Handler->find_scoped_handler($self->_scope_id)
                    // die "No scoped handler for effect (${base_name}::${op})\n";
                my $impl = $handler->{$op}
                    // die "No handler for ${base_name}::${op}\n";
                $impl->(@args);
            };
        }
    }

    $class->new(effect_name => $name, base_name => $base_name);
}

# ── Handle Support (scoped effect handler block) ──
#
#   handle { BODY } Effect => +{ op => sub ... }, ...;
#   handle { BODY } $scope => +{ op => sub ... }, ...;  (scoped)
#
# The (&@) prototype allows bare-block syntax at call sites.

sub _handle :prototype(&@) {
    my ($body, @handler_specs) = @_;

    # Scan for Exn handler before consuming the spec list
    my $exn_handler;
    {
        my @scan = @handler_specs;
        while (@scan >= 2) {
            my ($eff, $handlers) = splice(@scan, 0, 2);
            if (!ref $eff && $eff eq 'Exn') { $exn_handler = $handlers; last }
        }
    }

    # Push all effect handlers onto the stack
    my $pushed = 0;
    while (@handler_specs >= 2) {
        my $effect   = shift @handler_specs;
        my $handlers = shift @handler_specs;
        if (ref $effect && $effect->isa('Typist::EffectScope')) {
            # Scoped dispatch: bind handler to this specific scope identity
            Typist::Handler->push_scoped_handler($effect->_scope_id, $handlers);
        } else {
            # Name-based dispatch: extract base name from parameterized spec
            my ($base_effect) = $effect =~ /\A(\w+)/;
            Typist::Handler->push_handler($base_effect, $handlers);
        }
        $pushed++;
    }

    # Execute body, ensuring handlers are popped even on exception
    my @result;
    my $ok = eval {
        @result = $body->();
        1;
    };
    my $err = $@;

    # Pop handlers (LIFO — matches push order)
    Typist::Handler->pop_handler for 1 .. $pushed;

    # On exception: delegate to Exn handler or re-raise
    unless ($ok) {
        if ($exn_handler && $exn_handler->{throw}) {
            my @r = $exn_handler->{throw}->($err);
            return wantarray ? @r : $r[0];
        }
        die $err;
    }

    wantarray ? @result : $result[0];
}

1;
