!> @brief Shows that a Fortran program can have a perfectly ordinary CLI.
!>
!> @details Build and run:
!>
!>          make
!>          ./build/cli_demo --levels=30 -v mesh_C24.nc
!>          ./build/cli_demo --help
program cli_demo

  use, intrinsic :: iso_fortran_env, only : output_unit, real64
  use cli_args_mod, only : argument, argument_count, has_flag, &
                           option_value, positional

  implicit none

  integer,  parameter :: r_def = real64

  character(:), allocatable :: mesh_file
  character(:), allocatable :: levels_text
  character(:), allocatable :: dt_text
  integer                   :: n_levels, ios
  real(r_def)               :: dt
  logical                   :: verbose

  if (has_flag('--help') .or. has_flag('-h') .or. argument_count() == 0) then
    call print_usage()
    stop 0
  end if

  verbose     = has_flag('--verbose') .or. has_flag('-v')
  levels_text = option_value('--levels', '30')
  mesh_file   = positional(1)

  read( levels_text, *, iostat=ios ) n_levels
  if (ios /= 0) then
    write( output_unit, '("cli_demo: --levels needs an integer, got ",A)' ) levels_text
    stop 2
  end if

  ! An internal read needs a character *variable*, not an expression: the unit
  ! of `read(u, ...)` is either an integer unit number or a variable whose
  ! contents are the "file". `read(option_value(...), *)` will not compile.
  dt_text = option_value('--dt', '300.0')
  read( dt_text, *, iostat=ios ) dt
  if (ios /= 0) then
    write( output_unit, '("cli_demo: --dt needs a number, got ",A)' ) dt_text
    stop 2
  end if

  write( output_unit, '("mesh file : ",A)'    ) trim(mesh_file)
  write( output_unit, '("levels    : ",I0)'   ) n_levels
  write( output_unit, '("timestep  : ",F0.1)' ) dt
  write( output_unit, '("verbose   : ",L1)'   ) verbose

contains

  !> @brief Print the usage message.
  subroutine print_usage()

    implicit none

    write( output_unit, '(A)' ) 'usage: ' // argument(0) // ' [options] MESH_FILE'
    write( output_unit, '(A)' ) ''
    write( output_unit, '(A)' ) '  --levels N     number of vertical levels (default 30)'
    write( output_unit, '(A)' ) '  --dt SECONDS   timestep (default 300.0)'
    write( output_unit, '(A)' ) '  -v, --verbose  chatter'
    write( output_unit, '(A)' ) '  -h, --help     this message'

  end subroutine print_usage

end program cli_demo
