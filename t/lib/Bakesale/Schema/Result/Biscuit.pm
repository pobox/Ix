use strict;
use warnings;
use experimental qw(postderef signatures);
package Bakesale::Schema::Result::Biscuit;
use base qw/DBIx::Class::Core/;
use DateTime;
use Ix::Validators qw(idstr);
use Ix::Util qw(differ);
use List::Util qw(first);

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('biscuits');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type => { data_type => 'string', client_may_init => 1, client_may_update => 0 },
  qty  => { data_type => 'integer', is_optional => 1, client_may_init => 0, client_may_update => 1 },
  size => { data_type => 'string',  is_optional => 1, is_immutable => 1 },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'Biscuit' }

sub ix_account_type { 'generic' }

1;
