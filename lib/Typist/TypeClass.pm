package Typist::TypeClass;
use v5.40;

# Type class definition and instance structures.
#
# A type class defines an interface:
#   { name => 'Eq', var => 'T', methods => { eq => sig, neq => sig }, supers => [] }
#
# An instance provides implementations for a specific type:
#   { class => 'Eq', type_expr => 'Int', methods => { eq => coderef, neq => coderef } }

sub new_class ($class, %args) {
    my $var_spec = $args{var} // 'T';
    my ($var_name, $var_kind_str);

    # Parse "F: * -> *" syntax for HKT
    if ($var_spec =~ /\A(\w+)\s*:\s*(.+)\z/) {
        $var_name     = $1;
        $var_kind_str = $2;
    } else {
        $var_name     = $var_spec;
        $var_kind_str = undef;
    }

    bless +{
        name         => ($args{name}    // die("TypeClass requires name\n")),
        var          => $var_name,
        var_kind_str => $var_kind_str,
        methods      => ($args{methods} // +{}),
        supers       => ($args{supers}  // []),
    }, "${class}::Def";
}

sub new_instance ($class, %args) {
    bless +{
        class     => ($args{class}     // die("Instance requires class\n")),
        type_expr => ($args{type_expr} // die("Instance requires type_expr\n")),
        methods   => ($args{methods}   // +{}),
    }, "${class}::Inst";
}

# ── Class Definition ─────────────────────────────

package Typist::TypeClass::Def;
use v5.40;

sub name         ($self) { $self->{name} }
sub var          ($self) { $self->{var} }
sub var_kind_str ($self) { $self->{var_kind_str} }
sub methods      ($self) { $self->{methods}->%* }
sub supers       ($self) { $self->{supers}->@* }

sub method_names ($self) { sort keys $self->{methods}->%* }

# ── Instance ─────────────────────────────────────

package Typist::TypeClass::Inst;
use v5.40;

sub class     ($self) { $self->{class} }
sub type_expr ($self) { $self->{type_expr} }
sub methods   ($self) { $self->{methods}->%* }

sub get_method ($self, $name) { $self->{methods}{$name} }

1;
