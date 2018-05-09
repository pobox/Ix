use strict;
use warnings;
package Bakesale::Schema::Result::CakeRecipe;
use base qw/DBIx::Class::Core/;

use JSON::MaybeXS ();

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('cake_recipes');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type         => { data_type => 'string',  },
  avg_review   => { data_type => 'integer', },
  is_delicious => { data_type => 'boolean', },
  sku          => { data_type => 'string',  },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'CakeRecipe' }

sub ix_account_type { 'generic' }

our $NEXT_SKU = '12345';

sub ix_default_properties {
  return {
    is_delicious => JSON::MaybeXS::JSON->true(),
    sku => sub { $NEXT_SKU++ },
  };
}

1;
