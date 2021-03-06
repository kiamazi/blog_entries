use Module::Info;

has template => (
    traits  => [ 'Mustache' ],
    handles => { render_mustache => 'render' },
    is      => 'ro',
    lazy    => 1,
    default => sub($self) {
        join '',
            grep { !/^=(begin|end|cut)/ }
            grep { 
                /^=begin\s+template\s*$/
                    ../^=(?:end\s+template|cut)\s*$/ 
            } 
        path(
            Module::Info
                ->new_from_module($self->meta->name)
                ->file 
        )->lines;
    },
);
