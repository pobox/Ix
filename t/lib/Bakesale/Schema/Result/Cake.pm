use strict;
use warnings;
use experimental qw(postderef signatures);
package Bakesale::Schema::Result::Cake;
use base qw/DBIx::Class::Core/;

use Ix::Validators qw(integer nonemptystr idstr);
use List::Util qw(max);

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('cakes');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type        => { data_type => 'string',     },
  layer_count => { data_type => 'integer',  validator => integer(1, 10)  },
  baked_at    => { data_type => 'datetime', is_immutable => 1 },
  recipeId    => {
    data_type    => 'string',
    db_data_type => 'integer',
    validator    => idstr(),
    xref_to      => 'cakeRecipes'
  },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
  recipe => 'Bakesale::Schema::Result::CakeRecipe',
  { 'foreign.id' => 'self.recipeId' },
);

sub ix_type_key { 'cakes' }

sub ix_account_type { 'generic' }

sub ix_default_properties {
  return { baked_at => Ix::DateTime->now };
}

sub ix_get_check ($self, $ctx, $arg) {
  return if $arg->{ids};

  return $ctx->error(invalidArguments => {
    description => "required parameter 'ids' not present",
  });
}

sub ix_state_string ($self, $state) {
  return join q{-},
    $state->state_for($self->ix_type_key),
    $state->state_for('cakeRecipes');
}

sub ix_compare_state ($self, $since, $state) {
  my ($cake_since, $recipe_since) = split /-/, $since, 2;

  return Ix::StateComparison->bogus
    unless ($cake_since//'')    =~ /\A[0-9]+\z/
        && ($recipe_since//'')  =~ /\A[0-9]+\z/;

  my $cake_high   = $state->highest_modseq_for('cakes');
  my $recipe_high = $state->highest_modseq_for('cakeRecipes');

  my $cake_low    = $state->lowest_modseq_for('cakes');
  my $recipe_low  = $state->lowest_modseq_for('cakeRecipes');

  if ($cake_high < $cake_since || $recipe_high < $recipe_since) {
    return Ix::StateComparison->bogus;
  }

  if ($cake_low > $cake_since || $recipe_low > $recipe_since) {
    return Ix::StateComparison->resync;
  }

  if ($cake_high == $cake_since && $recipe_high == $recipe_since) {
    return Ix::StateComparison->in_sync;
  }

  return Ix::StateComparison->okay;
}

sub ix_update_state_string_field { 'jointModSeq' }

sub ix_highest_state ($self, $since, $rows) {
  my ($cake_since,  $recipe_since)  = split /-/, $since, 2;

  my @r_updates = grep { $_->{jointModSeq} =~ /A-/ } @$rows;
  my @c_updates = grep { $_->{jointModSeq} =~ /B-/ } @$rows;

  my ($r_max) = @r_updates ? ($r_updates[-1]{jointModSeq} =~ /-([0-9]+)\z/) : $recipe_since;
  my ($c_max) = @c_updates ? ($c_updates[-1]{jointModSeq} =~ /-([0-9]+)\z/) : $cake_since;

  return "$c_max-$r_max";
}

sub ix_update_extra_search ($self, $ctx, $arg) {
  my $since = $arg->{since};

  my ($cake_since, $recipe_since) = split /-/, $since, 2;
  die "bogus state?!"
    unless ($cake_since//'')    =~ /\A[0-9]+\z/
        && ($recipe_since//'')  =~ /\A[0-9]+\z/;

  return(
    {
      -or => [
        'me.modSeqChanged'     => { '>' => $cake_since },
        'recipe.modSeqChanged' => { '>' => $recipe_since },
      ],
    },
    {
      '+columns' => {
        jointModSeq  => \[
          q{(CASE WHEN ? < recipe."modSeqChanged" THEN ('A-' || recipe."modSeqChanged") ELSE ('B-' || me."modSeqChanged") END)},
          $recipe_since,
        ],
      },
      join => [ 'recipe' ],

      order_by => [
        # Here, we only do A/B because we can't sort by A-n/B-n, because A-11
        # will sort before A-2.  On the other hand, we only use the jointModSeq
        # above for checking equality, not ordering, so it is appropriate to
        # use a string. -- rjbs, 2016-05-09
        \[
          q{(CASE WHEN ? < recipe."modSeqChanged" THEN 'A' ELSE 'B' END)},
          $recipe_since,
        ],
        \[
          q{(CASE WHEN ? < recipe."modSeqChanged" THEN recipe."modSeqChanged" ELSE me."modSeqChanged" END)},
          $recipe_since,
        ],
      ],
    },
  );
}

sub ix_update_single_state_conds ($self, $example_row) {
  if ($example_row->{jointModSeq} =~ /\AA-([0-9]+)\z/) {
    return { 'recipe.modSeqChanged' => "$1" }
  } elsif ($example_row->{jointModSeq} =~ /\AB-([0-9]+)\z/) {
    return { 'me.modSeqChanged' => "$1" }
  }

  Carp::confess("Unreachable code reached.");
}

sub ix_created ($self, $ctx, $row) {
  return unless $row->type eq 'wedding';

  my $handler = $ctx->processor->handler_for('setCakeToppers');

  my @results = $ctx->processor->$handler($ctx, {
    create => { $row->id => { cakeId => $row->id } },
  });

  for my $result (@results) {
    if ($result->{not_created} || $ENV{NO_CAKE_TOPPERS}) {
      die $ctx->internal_error("failed to create cake topper");
    }
  }

  return;
}

sub ix_postprocess_set ($self, $ctx, $results) {
  # Wedding cakes have toppers maybe!
  for my $result (@$results) {
    my @cake_ids = map { $_->{id} } values $result->{created}->%*;
    next unless @cake_ids;

    my @tids = $ctx->schema->resultset('CakeTopper')->search(
      { cakeId => [ @cake_ids ] },
    )->get_column('id')->all;
    next unless @tids;

    my $handler = $ctx->processor->handler_for('getCakeToppers');
    push @$results, $ctx->processor->$handler($ctx, { ids => [ @tids ] });
  }

  return;
}

sub ix_get_list_sort_map {
  return {
    layer_count => { },
    baked_at    => { },
    recipeId    => { },
    type        => { sort_by => \"
      CASE me.type
        WHEN 'chocolate' THEN 1
        WHEN 'marble'    THEN 2
        ELSE                  3
      END
    "},
  };
}

sub ix_get_list_filter_map {
  return {
    recipeId    => { required => 1 },
    type        => { },
    layer_count => { },
  };
}

sub ix_get_list_fetchable_map {
  return {
    fetchRecipes => {
      field      => 'recipeId',
      result_set => 'CakeRecipe',
    },
  };
}

sub ix_get_list_joins {
  return ('recipe');
}

sub ix_get_list_check ($self, $ctx, $arg, $search) {
  if (
       exists $arg->{filter}
    && exists $arg->{filter}{recipeId}
    && ($arg->{filter}{recipeId} // '') eq 'secret'
  ) {
    return $ctx->error(invalidArguments => {
      description => "That recipe is too secret for you",
    });
  }
}

sub ix_get_list_updates_check ($self, $ctx, $arg, $search) {
  if (
       exists $arg->{filter}
    && exists $arg->{filter}{recipeId}
    && ($arg->{filter}{recipeId} // '') eq 'secret'
  ) {
    return $ctx->error(invalidArguments => {
      description => "That recipe is way too secret for you",
    });
  }
}

sub ix_get_list_enabled { 1 }


1;
