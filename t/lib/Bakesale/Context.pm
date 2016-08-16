package Bakesale::Context {;
  use Moose;

  use experimental qw(lexical_subs signatures postderef);

  use Data::GUID qw(guid_string);

  use namespace::autoclean;

  sub is_system { 0 }

  sub file_exception_report {
    warn "EXCEPTION!!";
    return guid_string();
  }

  has userId => (
    is       => 'ro',
    required => 1,
  );

  has user => (
    isa      => 'Object',
    reader   => 'user',
    writer   => '_set_user',
    init_arg => undef,
    lazy     => 1,
    handles  => [ qw(datasetId) ],
    clearer  => '_clear_user', # trigger this after setUsers, surely?
    default  => sub ($self) {
      return $self->schema->resultset('User')->find($self->userId);
    },
  );

  with 'Ix::Context';
}

package Bakesale::Context::System {
  use Moose;

  use experimental qw(lexical_subs signatures postderef);

  use Data::GUID qw(guid_string);

  use namespace::autoclean;

  has datasetId => (is => 'ro', default => 1);

  sub is_system { 1 }

  with 'Ix::Context';
}

1;
