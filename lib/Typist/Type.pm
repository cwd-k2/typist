package Typist::Type;
use v5.40;

# Abstract base class for all type objects.
# Every type is an immutable value object sharing this interface.

sub name        { die ref(shift) . " must implement name()" }
sub to_string   { die ref(shift) . " must implement to_string()" }
sub equals      { die ref(shift) . " must implement equals()" }
sub contains    { die ref(shift) . " must implement contains()" }
sub free_vars   { die ref(shift) . " must implement free_vars()" }
sub substitute  { die ref(shift) . " must implement substitute()" }

sub is_atom         { 0 }
sub is_param        { 0 }
sub is_union        { 0 }
sub is_intersection { 0 }
sub is_func         { 0 }
sub is_struct       { 0 }
sub is_var          { 0 }
sub is_alias        { 0 }

1;
