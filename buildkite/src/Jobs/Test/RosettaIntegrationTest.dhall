let Prelude = ../../External/Prelude.dhall
let Cmd = ../../Lib/Cmds.dhall
let S = ../../Lib/SelectFiles.dhall
let Pipeline = ../../Pipeline/Dsl.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall
let Command = ../../Command/Base.dhall
let OpamInit = ../../Command/OpamInit.dhall
let Docker = ../../Command/Docker/Type.dhall
let Size = ../../Command/Size.dhall
in

Pipeline.build
  Pipeline.Config::
    { spec =
      JobSpec::
        { dirtyWhen =
          [ S.strictlyStart (S.contains "src/app")
          , S.strictlyStart (S.contains "src/lib")
          , S.strictly (S.contains "Makefile")
          , S.strictlyStart (Scontains "buildkite/src/Jobs/Test/RosettaIntegrationTest")
          ]
        , path = "Test"
        , name = "RosettaIntegrationTest"
        }
    , steps =
      [ Command.build
          Command.Config::
            { commands =
              OpamInit.andThenRunInDocker
                [  "(cd src/app/rosetta && ./docker-test-start.sh)" ]
            , label = "Rosetta integration tests"
            , key = "rosetta-integration-tests"
            , target = Size.Large
            , docker = None Docker.Type
            }
      ]
    }
