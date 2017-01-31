use 5.20.0;
use warnings;
package Ix::DBIC::StatesResult;

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

sub ix_setup_states_result ($class) {
  $class->add_columns(
    accountId     => { data_type => 'bigint' },
    type          => { data_type => 'text' },
    lowestModSeq  => { data_type => 'bigint' },
    highestModSeq => { data_type => 'bigint' },
  );

  $class->set_primary_key(qw( accountId type ));
}

1;
