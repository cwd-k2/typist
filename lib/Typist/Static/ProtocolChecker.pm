package Typist::Static::ProtocolChecker;
use v5.40;

our $VERSION = '0.01';

# Static protocol state-machine checker.
# Verifies that effect operations are called in the correct order
# according to the protocol's finite state machine.

sub new ($class, %args) {
    bless +{
        registry  => $args{registry},
        errors    => $args{errors},
        extracted => $args{extracted},
        ppi_doc   => $args{ppi_doc},
        file      => $args{file} // '(buffer)',
        hints     => [],
    }, $class;
}

sub hints ($self) { $self->{hints} }

sub analyze ($self) {
    my $pkg = $self->{extracted}{package};

    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        next if $fn->{unannotated};
        my $block = $fn->{block} // next;

        my $caller_sig = $self->{registry}->lookup_function($pkg, $name);
        next unless $caller_sig;
        next unless $caller_sig->{effects};

        my $caller_eff = $caller_sig->{effects};
        my $row = $caller_eff->is_eff ? $caller_eff->row : $caller_eff;
        next unless $row->is_row;

        # For each label with protocol state annotation, trace the body
        for my $label ($row->labels) {
            my $state_range = $row->label_state($label) // next;
            my $effect = $self->{registry}->lookup_effect($label);
            next unless $effect && $effect->has_protocol;

            my $protocol = $effect->protocol;
            $self->_trace_body(
                $block, $name, $label, $protocol,
                $state_range->{from}, $state_range->{to}, $pkg,
            );
        }
    }
}

sub _trace_body ($self, $block, $fn_name, $label, $protocol, $from, $to, $pkg) {
    my $current = $from;
    my $words = $block->find('PPI::Token::Word') || [];

    for my $word (@$words) {
        my $content = $word->content;

        # Pattern 1: Direct effect operation — Label::op(...)
        if ($content =~ /\A${label}::(\w+)\z/) {
            my $op = $1;
            my $next = $word->snext_sibling;
            # Must be followed by a List (call pattern)
            next unless $next && ref $next && $next->isa('PPI::Structure::List');

            my $next_state = $protocol->next_state($current, $op);
            if (!defined $next_state) {
                $self->{errors}->collect(
                    kind    => 'ProtocolMismatch',
                    message => "Protocol $label: operation '$op' is not allowed "
                             . "in state '$current' (in $fn_name())",
                    file    => $self->{file},
                    line    => $word->line_number,
                    col     => $word->column_number,
                    end_col => $word->column_number + length($content),
                );
            } else {
                push $self->{hints}->@*, +{
                    label => $label,
                    op    => $op,
                    from  => $current,
                    to    => $next_state,
                    line  => $word->line_number,
                    col   => $word->column_number,
                };
                $current = $next_state;
            }
            next;
        }

        # Pattern 2: Function call with protocol annotation — f(...)
        next if $content =~ /\A(?:my|our|local|return|if|unless|for|foreach|while|until|do|sub|use|no|handle|match)\z/;
        my $prev = $word->sprevious_sibling;
        next if $prev && ref $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->';
        my $next_sib = $word->snext_sibling;
        next if $next_sib && ref $next_sib && $next_sib->isa('PPI::Token::Operator') && $next_sib->content eq '=>';
        next unless $next_sib && ref $next_sib && $next_sib->isa('PPI::Structure::List');

        # Look up callee sig
        my $callee_sig = $self->{registry}->lookup_function($pkg, $content);
        unless ($callee_sig) {
            if ($content =~ /\A(.+)::(\w+)\z/) {
                $callee_sig = $self->{registry}->lookup_function($1, $2);
            }
        }
        next unless $callee_sig && $callee_sig->{effects};

        my $callee_eff = $callee_sig->{effects};
        my $callee_row = $callee_eff->is_eff ? $callee_eff->row : $callee_eff;
        next unless $callee_row->is_row;

        my $callee_state = $callee_row->label_state($label) // next;

        # Verify from-state matches current
        if ($callee_state->{from} ne $current) {
            $self->{errors}->collect(
                kind    => 'ProtocolMismatch',
                message => "Protocol $label: $content() expects state '$callee_state->{from}' "
                         . "but current state is '$current' (in $fn_name())",
                file    => $self->{file},
                line    => $word->line_number,
                col     => $word->column_number,
                end_col => $word->column_number + length($content),
            );
        } else {
            push $self->{hints}->@*, +{
                label => $label,
                op    => $content,
                from  => $current,
                to    => $callee_state->{to},
                line  => $word->line_number,
                col   => $word->column_number,
            };
            $current = $callee_state->{to};
        }
    }

    # Final state check
    if ($current ne $to) {
        $self->{errors}->collect(
            kind    => 'ProtocolMismatch',
            message => "Protocol $label: function $fn_name() ends in state '$current' "
                     . "but declared end state is '$to'",
            file    => $self->{file},
            line    => $self->{extracted}{functions}{$fn_name}{line},
            col     => $self->{extracted}{functions}{$fn_name}{col},
        );
    }
}

1;
