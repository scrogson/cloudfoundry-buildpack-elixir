function restore_app() {
  if [ $always_rebuild = true ]; then
    rm -rf ${build_path}/_build
  fi

  if [ $erlang_changed != true ] || [ $elixir_changed != true ]; then
    if [ -d $(deps_backup_path) ]; then
      cp -R $(deps_backup_path) ${build_path}/deps
    fi

    if [ -d $(build_backup_path) ]; then
      cp -R $(build_backup_path) ${build_path}/_build
    fi
  fi
}


function copy_hex() {
  mkdir -p ${build_path}/.mix/archives
  mkdir -p ${build_path}/.hex

  if [ -n "$hex_source" ]; then
    hex_file=`basename ${hex_source}`
  else
    # hex file names after elixir-1.1 in the hex-<version>.ez form
    full_hex_file_path=$(ls -t ${HOME}/.mix/archives/hex-*.ez | head -n 1)

    # For older versions of hex which have no version name in file
    if [ -z "$full_hex_file_path" ]; then
      full_hex_file_path=${HOME}/.mix/archives/hex.ez
    fi
  fi

  cp ${HOME}/.hex/registry.ets ${build_path}/.hex/

  output_section "Copying hex from $full_hex_file_path"
  cp $full_hex_file_path ${build_path}/.mix/archives
}


function app_dependencies() {
  local git_dir_value=$GIT_DIR

  # Enter build dir to perform app-related actions
  cd $build_path

  # Unset this var so that if the parent dir is a git repo, it isn't detected
  # And all git operations are performed on the respective repos
  unset GIT_DIR

  (
    if [ "$GIT_SSH_KEY" != "" ]; then   
      status "Detected SSH key for git.  launching ssh-agent and loading key"
      echo $GIT_SSH_KEY | base64 --decode > id_rsa
      chmod 0600 id_rsa
      # launch ssh-agent, we'll use it to serve our ssh key
      # and kill it towards the end of the buildpack's run
      eval `ssh-agent -s`
      # We're not supporting passphrases at this time.  We could pull that in
      # from config as well, but then we'd have to setup expect or some other
      # terminal automation tool to feed it into ssh-add.
      ssh-add id_rsa
      rm id_rsa
      # Add github to the list of known hosts - ignore the warning or else set -e will abort the deployment
      ssh -oStrictHostKeyChecking=no -T git@$GIT_HOST || true
    fi  
  
    output_section "Fetching app dependencies with mix"
    mix deps.get --only prod || exit 1
  
    output_section "Compiling app dependencies"
    mix deps.check || exit 1
  
    if [ "$GIT_SSH_KEY" != "" ]; then
      # Now that mix has finished running, we shouldn't need the ssh key anymore.  Kill ssh-agent
      eval `ssh-agent -k`
      # Clear that sensitive key data from the environment
      export GIT_SSH_KEY=0
    fi
  )

  export GIT_DIR=$git_dir_value
  cd - > /dev/null
}


function backup_app() {
  # Delete the previous backups
  rm -rf $(deps_backup_path) $(build_backup_path)

  cp -R ${build_path}/deps $(deps_backup_path)
  cp -R ${build_path}/_build $(build_backup_path)
}


function compile_app() {
  local git_dir_value=$GIT_DIR
  unset GIT_DIR

  cd $build_path
  output_section "Compiling the app"

  # We need to force compilation of the application because
  # Heroku and our caching mess with the files mtime

  mix compile --force || exit 1
  mix compile.protocols || exit 1

  export GIT_DIR=$git_dir_value
  cd - > /dev/null
}


function write_profile_d_script() {
  output_section "Creating .profile.d with env vars"
  mkdir $build_path/.profile.d

  local export_line="export PATH=\$HOME/.platform_tools:\$HOME/.platform_tools/erlang/bin:\$HOME/.platform_tools/elixir/bin:\$PATH
                     export LC_CTYPE=en_US.utf8
                     export MIX_ENV=${MIX_ENV}"
  echo $export_line >> $build_path/.profile.d/elixir_buildpack_paths.sh
}
