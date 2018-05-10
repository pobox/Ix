use strict;
use warnings;
use experimental qw(postderef signatures);
package Bakesale::Schema::Result::CakeTopper;
use base qw/DBIx::Class::Core/;

use Ix::Validators qw(integer nonemptystr idstr);
use List::Util qw(max);

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('cake_toppers');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type   => { data_type => 'string',     },
  cakeId => {
    data_type    => 'idstr',
    xref_to      => 'Cake'
  },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'CakeTopper' }

sub ix_account_type { 'generic' }

sub ix_default_properties {
  return { type => 'wedding' };
}

__PACKAGE__->belongs_to(
  cake => 'Bakesale::Schema::Result::Cake',
  { 'foreign.id' => 'self.cakeId' },
);

1;
