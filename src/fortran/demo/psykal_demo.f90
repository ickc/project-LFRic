!> @brief Runs the miniature PSyKAl stack and checks it against dense linear
!>        algebra.
!>
!> @details The whole of LFRic's software architecture, at a scale you can
!>          hold in your head:
!>
!>              psykal_demo.f90            driver: sets up, calls, checks
!>              mini_alg_mod.f90           algorithm layer: whole fields
!>              mini_psy_mod.f90           PSy layer: loops, colours, threads
!>              mini_matvec_kernel_mod.f90 kernel: one cell, arrays only
!>              mini_field_mod.f90         data model: field + proxy
!>              mini_function_space_mod    mesh and dofmap
!>              mini_argument_mod.f90      the metadata vocabulary
!>
!>          The check is worth doing for its own sake: assembling `M x` cell by
!>          cell with an indirection map is not obviously the same computation
!>          as multiplying by the global matrix, and seeing the two agree to
!>          machine precision is the fastest way to believe the dofmap.
program psykal_demo

  use, intrinsic :: iso_fortran_env, only : output_unit
  use mini_alg_mod,            only : apply_mass_matrix, build_mass_operator
  use mini_constants_mod,      only : i_def, r_def
  use mini_field_mod,          only : field_type, field_proxy_type
  use mini_function_space_mod, only : function_space_type

  implicit none

  integer(i_def), parameter :: ncell = 8_i_def

  type(function_space_type), target  :: w0_space
  type(function_space_type), pointer :: fs => null()
  type(field_type) :: x, lhs
  type(field_proxy_type) :: x_proxy, lhs_proxy
  real(r_def), allocatable :: mass_op(:,:,:)
  real(r_def), allocatable :: dense(:,:), reference(:)
  integer(i_def) :: cell, df1, df2, undf, i
  integer(i_def), allocatable :: map(:)
  real(r_def) :: worst

  call w0_space%initialise(ncell)
  fs => w0_space
  undf = fs%get_undf()

  call x%initialise(fs, 'x')
  call lhs%initialise(fs, 'lhs')

  ! Fill x with something not symmetric, so a wrong dofmap cannot hide.
  x_proxy = x%get_proxy()
  do i = 1, undf
    x_proxy%data(i) = real(i, r_def)
  end do

  mass_op = build_mass_operator(w0_space)

  ! ---- the algorithm-layer call, serial ---------------------------------
  call apply_mass_matrix(lhs, x, mass_op, threaded=.false.)
  lhs_proxy = lhs%get_proxy()

  ! ---- the same thing, densely ------------------------------------------
  allocate( dense(undf, undf), reference(undf), map(fs%get_ndf()) )
  dense(:,:) = 0.0_r_def
  do cell = 1, ncell
    map = fs%get_cell_dofmap(cell)
    do df2 = 1, fs%get_ndf()
      do df1 = 1, fs%get_ndf()
        dense(map(df1), map(df2)) = dense(map(df1), map(df2)) &
                                  + mass_op(cell, df1, df2)
      end do
    end do
  end do
  reference = matmul(dense, x_proxy%data)

  worst = maxval(abs(lhs_proxy%data - reference))
  write( output_unit, '("cells                : ",I0)'      ) ncell
  write( output_unit, '("unique dofs          : ",I0)'      ) undf
  write( output_unit, '("serial   max |diff|  : ",ES10.3)'  ) worst

  ! ---- and again, threaded over colours ---------------------------------
  call apply_mass_matrix(lhs, x, mass_op, threaded=.true.)
  lhs_proxy = lhs%get_proxy()
  worst = maxval(abs(lhs_proxy%data - reference))
  write( output_unit, '("coloured max |diff|  : ",ES10.3)'  ) worst

  write( output_unit, '(A)' ) ''
  write( output_unit, '("M x, first five dofs : ",5(F8.4,1X))' ) lhs_proxy%data(1:5)

  if (worst > 1.0e-12_r_def) then
    write( output_unit, '(A)' ) 'FAILED: assembled and dense results disagree'
    stop 1
  end if
  write( output_unit, '(A)' ) 'ok'

  deallocate( dense, reference, map )

end program psykal_demo
