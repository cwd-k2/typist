package Typist::Static::EffectChecker;
use v5.40;

use Typist::Type::Row;
use Typist::Type::Eff;

# PPI-based static effect checker.
# Verifies that each function's body only calls functions whose effects
# are included in the caller's declared effect row.

sub new ($class, %args) {
    bless +{
        registry  => $args{registry},
        errors    => $args{errors},
        extracted => $args{extracted},
        ppi_doc   => $args{ppi_doc},
        file      => $args{file} // '(buffer)',
    }, $class;
}

sub analyze ($self) {
    my $pkg = $self->{extracted}{package};

    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn    = $self->{extracted}{functions}{$name};
        my $block = $fn->{block} // next;

        # Skip unannotated callers — they are Eff(*) themselves
        next if $fn->{unannotated};

        # Lookup the caller's registered sig
        my $caller_sig = $self->{registry}->lookup_function($pkg, $name);
        next unless $caller_sig;

        my $caller_eff = $caller_sig->{effects};

        # Collect called functions and their effects
        my @called = $self->_collect_called_effects($block, $pkg);

        for my $call (@called) {
            my $callee_eff = $call->{effects};
            next unless $callee_eff;

            # Callee is unannotated (open row with *) → any effect
            if ($call->{unannotated}) {
                $self->{errors}->collect(
                    kind    => 'EffectMismatch',
                    message => "Function $name() calls unannotated $call->{name}()"
                             . " which may perform any effect",
                    file    => $self->{file},
                    line    => $call->{line},
                );
                next;
            }

            # Caller has no effects declared but callee does
            unless ($caller_eff) {
                $self->{errors}->collect(
                    kind    => 'EffectMismatch',
                    message => "Function $name() calls $call->{name}() which requires "
                             . $callee_eff->to_string
                             . ", but $name() has no :Eff annotation",
                    file    => $self->{file},
                    line    => $call->{line},
                );
                next;
            }

            # Check effect inclusion: callee's labels ⊆ caller's labels
            $self->_check_effect_inclusion(
                $caller_eff, $callee_eff,
                $name, $call->{name}, $call->{line},
            );
        }
    }
}

sub _collect_called_effects ($self, $block, $pkg) {
    my @calls;
    my $words = $block->find('PPI::Token::Word') || [];

    for my $word (@$words) {
        my $callee_name = $word->content;

        # Skip keywords
        next if $callee_name =~ /\A(?:my|our|local|return|if|unless|for|foreach|while|until|do|eval|sub|use|no)\z/;

        # Must be followed by a list (function call pattern)
        my $next = $word->snext_sibling // next;
        next unless ref $next && $next->isa('PPI::Structure::List');

        # Skip if it's a sub declaration
        my $parent = $word->parent;
        next if $parent && $parent->isa('PPI::Statement::Sub');

        # Look up callee's sig — local package first, then cross-package (Pkg::func)
        my $callee_sig = $self->{registry}->lookup_function($pkg, $callee_name);
        unless ($callee_sig) {
            if ($callee_name =~ /\A(.+)::(\w+)\z/) {
                $callee_sig = $self->{registry}->lookup_function($1, $2);
            }
        }
        next unless $callee_sig;
        next unless $callee_sig->{effects};

        # Detect unannotated function: open row with row_var '*'
        my $eff = $callee_sig->{effects};
        my $row = $eff->is_eff ? $eff->row : $eff;
        my $is_unannotated = $row->is_row && ($row->row_var_name // '') eq '*';

        push @calls, +{
            name        => $callee_name,
            effects     => $eff,
            unannotated => $is_unannotated,
            line        => $word->line_number,
        };
    }

    @calls;
}

sub _check_effect_inclusion ($self, $caller_eff, $callee_eff, $caller_name, $callee_name, $line) {
    my $caller_row = $caller_eff->is_eff ? $caller_eff->row : $caller_eff;
    my $callee_row = $callee_eff->is_eff ? $callee_eff->row : $callee_eff;

    # If either has row variables, skip (needs runtime unification)
    return if !$caller_row->is_closed || !$callee_row->is_closed;

    my %caller_labels = map { $_ => 1 } $caller_row->labels;

    for my $label ($callee_row->labels) {
        unless ($caller_labels{$label}) {
            $self->{errors}->collect(
                kind    => 'EffectMismatch',
                message => "Function $caller_name() calls $callee_name() which requires "
                         . "effect '$label', but $caller_name() does not declare it",
                file    => $self->{file},
                line    => $line,
            );
        }
    }
}

1;
