package Bakesale::Schema::Result::CakeRecipe;
use base qw/DBIx::Class::Core/;

use JSON ();

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('cake_recipes');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type         => { data_type => 'text',    },
  avg_review   => { data_type => 'integer', },
  is_delicious => { data_type => 'boolean', },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'cakeRecipes' }

sub ix_default_properties {
  return {
    is_delicious => JSON::true,
  };
}

1;
