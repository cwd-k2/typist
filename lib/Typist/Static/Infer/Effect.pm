package Typist::Static::Infer;
use v5.40;

# ── Effect Handler Inference ─────────────────────
#
# Walks handle { BODY } Effect => +{ op => sub {...} } siblings,
# resolves effect op signatures from the registry, and drives
# bidirectional param injection into handler subs.

sub _infer_handle_handlers ($body_block, $env) {
    my $registry = ($env // +{})->{registry} // return;
    my $sib = $body_block->snext_sibling;
    my $current_effect;
    my $current_type_args;  # type arg substitution map for parameterized effects

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        # Effect name: Word followed by =>
        if ($sib->isa('PPI::Token::Word')) {
            my $after = $sib->snext_sibling;
            if ($after && $after->isa('PPI::Token::Operator') && $after->content eq '=>') {
                $current_effect = $sib->content;
                $current_type_args = undef;
            }
        }
        # Scoped effect: $var followed by => — resolve via env
        elsif ($sib->isa('PPI::Token::Symbol')) {
            my $after = $sib->snext_sibling;
            if ($after && $after->isa('PPI::Token::Operator') && $after->content eq '=>') {
                my $var_type = ($env->{variables} // +{})->{$sib->content};
                if ($var_type && $var_type =~ /EffectScope\[(\w+)(?:\[(.+)\])?\]/) {
                    $current_effect = $1;
                    $current_type_args = _build_effect_type_args($1, $2, $registry);
                }
            }
        }

        # Handler map: Constructor +{...}
        if ($sib->isa('PPI::Structure::Constructor') && $current_effect) {
            _infer_handler_map($sib, $current_effect, $env, $current_type_args);
        }

        $sib = $sib->snext_sibling;
    }
}

# Build type param → type arg substitution map for parameterized effects.
# e.g., effect 'Counter[S]' with args 'Int' → { S => Int }
sub _build_effect_type_args ($effect_name, $args_str, $registry) {
    return undef unless $args_str;
    my $eff = $registry->lookup_effect($effect_name) // return undef;
    my @type_params = ($eff->{type_params} // [])->@*;
    return undef unless @type_params;

    my @type_args = split /,\s*/, $args_str;
    return undef unless @type_params == @type_args;

    require Typist::Parser;
    my %subst;
    for my $i (0 .. $#type_params) {
        $subst{$type_params[$i]} = Typist::Parser->parse($type_args[$i]);
    }
    \%subst;
}

sub _infer_handler_map ($constructor, $effect_name, $env, $type_args = undef) {
    my $registry = $env->{registry} // return;
    my $expr = $constructor->find_first('PPI::Statement::Expression') // return;
    my $current_op;

    for my $child ($expr->schildren) {
        # Track op name: Word (not 'sub') followed by =>
        if ($child->isa('PPI::Token::Word') && $child->content ne 'sub') {
            my $after = $child->snext_sibling;
            if ($after && $after->isa('PPI::Token::Operator') && $after->content eq '=>') {
                $current_op = $child->content;
            }
        }

        # Found anonymous sub for the current op
        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub' && $current_op) {
            my $sig = $registry->lookup_function($effect_name, $current_op);
            if ($sig && $sig->{params}) {
                my @params  = $sig->{params}->@*;
                my $returns = $sig->{returns} // Typist::Type::Atom->new('Any');

                # Substitute type params for scoped effects (e.g., S → Int)
                if ($type_args) {
                    @params  = map { $_->substitute($type_args) } @params;
                    $returns = $returns->substitute($type_args);
                }

                my $expected = Typist::Type::Func->new(\@params, $returns);
                _infer_anon_sub($child, $env, $expected);
            }
        }
    }
}

1;
