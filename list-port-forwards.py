#!/usr/bin/env python3

import os
import yaml
import re
import pwd
import grp
from pathlib import Path

def load_env_file(env_file_path='.env'):
    """Load environment variables from .env file."""
    env_vars = {}
    
    if not os.path.exists(env_file_path):
        print(f"Warning: {env_file_path} file not found in current directory")
        return env_vars
    
    try:
        with open(env_file_path, 'r') as f:
            for line in f:
                line = line.strip()
                # Skip empty lines and comments
                if not line or line.startswith('#'):
                    continue
                
                # Parse KEY=VALUE format
                if '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    
                    # Remove quotes if present
                    if (value.startswith('"') and value.endswith('"')) or \
                       (value.startswith("'") and value.endswith("'")):
                        value = value[1:-1]
                    
                    env_vars[key] = value
        
        print(f"Loaded {len(env_vars)} variables from {env_file_path}")
        return env_vars
    
    except Exception as e:
        print(f"Error reading {env_file_path}: {e}")
        return env_vars

def extract_ports_from_yaml(yaml_file):
    """Extract port mappings from a single YAML file."""
    try:
        if not os.path.exists(yaml_file):
            print(f"Warning: File {yaml_file} not found")
            return []
        
        with open(yaml_file, 'r') as f:
            data = yaml.safe_load(f)
        
        if not data or 'services' not in data:
            return []
        
        port_mappings = []
        
        for service_name, service_config in data['services'].items():
            if 'ports' in service_config:
                for port_mapping in service_config['ports']:
                    # Handle different port mapping formats
                    if isinstance(port_mapping, str):
                        # Format: "host_port:container_port" or "host_port:container_port/protocol"
                        port_parts = port_mapping.split(':')
                        if len(port_parts) >= 2:
                            host_port = port_parts[0]
                            container_port = port_parts[1]
                            # Remove protocol suffix if present (e.g., "/udp")
                            host_port = re.sub(r'/\w+$', '', host_port)
                            container_port = re.sub(r'/\w+$', '', container_port)
                            port_mappings.append((service_name, host_port))
                    elif isinstance(port_mapping, int):
                        # Single port number
                        port_mappings.append((service_name, str(port_mapping)))
                    elif isinstance(port_mapping, dict):
                        # Long form port mapping
                        if 'published' in port_mapping:
                            port_mappings.append((service_name, str(port_mapping['published'])))
                        elif 'target' in port_mapping:
                            port_mappings.append((service_name, str(port_mapping['target'])))
        
        return port_mappings
    
    except Exception as e:
        print(f"Error parsing {yaml_file}: {e}")
        return []

def main():
    # Load .env file from current working directory
    env_vars = load_env_file()
    
    # Get COMPOSE_FILE from .env file or environment variable as fallback
    compose_file_env = env_vars.get('COMPOSE_FILE') or os.getenv('COMPOSE_FILE', '')
    
    if not compose_file_env:
        print("COMPOSE_FILE not found in .env file or environment variables")
        return
    
    print(f"Found COMPOSE_FILE: {compose_file_env[:100]}{'...' if len(compose_file_env) > 100 else ''}")
    print()
    
    # Split by colon to get individual YAML files
    yaml_files = compose_file_env.split(':')
    
    # Filter out excluded files
    excluded_files = {'home.yml', 'base.yml', 'rpc.yml'}
    filtered_files = []
    
    for yaml_file in yaml_files:
        yaml_file = yaml_file.strip()
        if yaml_file and Path(yaml_file).name not in excluded_files:
            filtered_files.append(yaml_file)
    
    print(f"Processing {len(filtered_files)} YAML files...")
    print("=" * 50)
    
    # Extract ports from each file
    all_port_mappings = []
    
    for yaml_file in filtered_files:
        port_mappings = extract_ports_from_yaml(yaml_file)
        all_port_mappings.extend(port_mappings)
        
        if port_mappings:
            print(f"\n{yaml_file}:")
            for service_name, port in port_mappings:
                print(f"  {service_name} : {port}")
    
    # Remove duplicates by converting to set then back to list
    unique_port_mappings = list(set(all_port_mappings))
    
    # Sort the unique mappings
    sorted_mappings = sorted(unique_port_mappings, key=lambda x: (x[0], int(x[1]) if x[1].isdigit() else x[1]))
    
    # Summary to console
    print("\n" + "=" * 50)
    print("SUMMARY - Unique Port Mappings:")
    print("=" * 50)
    
    for service_name, port in sorted_mappings:
        print(f"{service_name} : {port}")
    
    print(f"\nTotal unique port mappings found: {len(sorted_mappings)}")
    print(f"Duplicates removed: {len(all_port_mappings) - len(sorted_mappings)}")
    
    # Save to file (clean format, no whitespaces)
    output_file = os.path.expanduser("~payne/port-forward.txt")
    try:
        # Write the file
        with open(output_file, 'w') as f:
            for service_name, port in sorted_mappings:
                f.write(f"{service_name}:{port}\n")
        
        # Set ownership to payne:payne
        try:
            payne_user = pwd.getpwnam('payne')
            payne_group = grp.getgrnam('payne')
            os.chown(output_file, payne_user.pw_uid, payne_group.gr_gid)
        except KeyError:
            print("Warning: User or group 'payne' not found, skipping ownership change")
        except PermissionError:
            print("Warning: Permission denied setting ownership (you may need to run as root)")
        
        # Set read permissions for user payne (644: owner read/write, group read, others read)
        os.chmod(output_file, 0o644)
        
        print(f"\nResults saved to: {output_file}")
        print("File ownership set to payne:payne with read permissions")
    
    except Exception as e:
        print(f"\nError saving to {output_file}: {e}")
        print("You may need to run with sudo or check file permissions")

if __name__ == "__main__":
    main()
