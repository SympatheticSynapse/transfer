#!/usr/bin/env python3
"""
Bitbucket Dockerfile Scanner
Searches multiple Bitbucket projects and repositories for Dockerfiles,
extracts all base images from FROM statements, and outputs a deduplicated list.
"""

import requests
import re
import sys
from typing import Set, List, Dict
from requests.auth import HTTPBasicAuth
import argparse


class BitbucketDockerScanner:
    def __init__(self, base_url: str, username: str, password: str):
        """
        Initialize the Bitbucket scanner.
        
        Args:
            base_url: Bitbucket server URL (e.g., 'https://bitbucket.example.com')
            username: Bitbucket username
            password: Bitbucket password or API token
        """
        self.base_url = base_url.rstrip('/')
        self.auth = HTTPBasicAuth(username, password)
        self.session = requests.Session()
        self.session.auth = self.auth
        self.base_images: Set[str] = set()
    
    def get_projects(self, project_keys: List[str] = None) -> List[Dict]:
        """
        Get list of projects to scan.
        
        Args:
            project_keys: Optional list of specific project keys to scan
            
        Returns:
            List of project dictionaries
        """
        if project_keys:
            return [{'key': key} for key in project_keys]
        
        # If no specific projects, get all accessible projects
        projects = []
        url = f"{self.base_url}/rest/api/1.0/projects"
        
        while url:
            try:
                response = self.session.get(url)
                response.raise_for_status()
                data = response.json()
                
                projects.extend(data.get('values', []))
                
                # Check for pagination
                if data.get('isLastPage', True):
                    break
                url = f"{self.base_url}{data.get('nextPageStart', '')}"
                
            except requests.exceptions.RequestException as e:
                print(f"Error fetching projects: {e}", file=sys.stderr)
                break
        
        return projects
    
    def get_repositories(self, project_key: str) -> List[Dict]:
        """
        Get all repositories in a project.
        
        Args:
            project_key: Bitbucket project key
            
        Returns:
            List of repository dictionaries
        """
        repositories = []
        url = f"{self.base_url}/rest/api/1.0/projects/{project_key}/repos"
        
        while url:
            try:
                response = self.session.get(url, params={'limit': 100})
                response.raise_for_status()
                data = response.json()
                
                repositories.extend(data.get('values', []))
                
                # Check for pagination
                if data.get('isLastPage', True):
                    break
                url = f"{self.base_url}/rest/api/1.0/projects/{project_key}/repos"
                
            except requests.exceptions.RequestException as e:
                print(f"Error fetching repositories for project {project_key}: {e}", file=sys.stderr)
                break
        
        return repositories
    
    def search_dockerfiles(self, project_key: str, repo_slug: str) -> List[str]:
        """
        Search for Dockerfiles in a repository.
        
        Args:
            project_key: Bitbucket project key
            repo_slug: Repository slug
            
        Returns:
            List of Dockerfile paths
        """
        dockerfiles = []
        
        # Search for files named 'Dockerfile' or matching 'Dockerfile.*'
        search_patterns = ['Dockerfile', 'dockerfile']
        
        for pattern in search_patterns:
            url = f"{self.base_url}/rest/api/1.0/projects/{project_key}/repos/{repo_slug}/files"
            
            try:
                response = self.session.get(url, params={'limit': 1000})
                response.raise_for_status()
                data = response.json()
                
                # Filter files that are Dockerfiles
                for file_path in data.get('values', []):
                    file_name = file_path.split('/')[-1]
                    if (file_name == 'Dockerfile' or 
                        file_name.startswith('Dockerfile.') or
                        file_name == 'dockerfile' or
                        file_name.startswith('dockerfile.')):
                        dockerfiles.append(file_path)
                
            except requests.exceptions.RequestException as e:
                print(f"Error searching files in {project_key}/{repo_slug}: {e}", file=sys.stderr)
        
        return list(set(dockerfiles))  # Remove duplicates
    
    def get_file_content(self, project_key: str, repo_slug: str, file_path: str) -> str:
        """
        Get the content of a file from Bitbucket.
        
        Args:
            project_key: Bitbucket project key
            repo_slug: Repository slug
            file_path: Path to the file
            
        Returns:
            File content as string
        """
        url = f"{self.base_url}/rest/api/1.0/projects/{project_key}/repos/{repo_slug}/raw/{file_path}"
        
        try:
            response = self.session.get(url)
            response.raise_for_status()
            return response.text
        except requests.exceptions.RequestException as e:
            print(f"Error fetching file {file_path} from {project_key}/{repo_slug}: {e}", file=sys.stderr)
            return ""
    
    def extract_base_images(self, dockerfile_content: str) -> Set[str]:
        """
        Extract base images from Dockerfile content.
        
        Args:
            dockerfile_content: Content of the Dockerfile
            
        Returns:
            Set of base image names
        """
        images = set()
        
        # Regex pattern to match FROM statements
        # Matches: FROM image:tag, FROM --platform=... image:tag, FROM image AS alias
        pattern = r'^\s*FROM\s+(?:--platform=[^\s]+\s+)?([^\s]+)(?:\s+AS\s+[^\s]+)?'
        
        for line in dockerfile_content.split('\n'):
            # Skip comments
            if line.strip().startswith('#'):
                continue
            
            match = re.match(pattern, line, re.IGNORECASE)
            if match:
                image = match.group(1)
                # Skip build stage references (they don't have : or are lowercase aliases)
                if not image.startswith('$') and ':' in image or '/' in image or '@' in image:
                    images.add(image)
                elif not any(c.isupper() for c in image) and ':' not in image:
                    # Likely a reference to a build stage, skip it
                    continue
                else:
                    images.add(image)
        
        return images
    
    def scan(self, project_keys: List[str] = None) -> Set[str]:
        """
        Scan Bitbucket projects for Dockerfiles and extract base images.
        
        Args:
            project_keys: Optional list of specific project keys to scan
            
        Returns:
            Set of unique base images
        """
        projects = self.get_projects(project_keys)
        
        print(f"Scanning {len(projects)} project(s)...")
        
        for project in projects:
            project_key = project['key']
            print(f"\nScanning project: {project_key}")
            
            repositories = self.get_repositories(project_key)
            print(f"  Found {len(repositories)} repository(ies)")
            
            for repo in repositories:
                repo_slug = repo['slug']
                print(f"    Scanning repository: {repo_slug}")
                
                dockerfiles = self.search_dockerfiles(project_key, repo_slug)
                
                if dockerfiles:
                    print(f"      Found {len(dockerfiles)} Dockerfile(s)")
                    
                    for dockerfile_path in dockerfiles:
                        print(f"        Processing: {dockerfile_path}")
                        content = self.get_file_content(project_key, repo_slug, dockerfile_path)
                        
                        if content:
                            images = self.extract_base_images(content)
                            self.base_images.update(images)
                            if images:
                                print(f"          Extracted {len(images)} image(s)")
        
        return self.base_images


def main():
    parser = argparse.ArgumentParser(
        description='Search Bitbucket repositories for Dockerfiles and extract base images'
    )
    parser.add_argument(
        '--url',
        required=True,
        help='Bitbucket server URL (e.g., https://bitbucket.example.com)'
    )
    parser.add_argument(
        '--username',
        required=True,
        help='Bitbucket username'
    )
    parser.add_argument(
        '--password',
        required=True,
        help='Bitbucket password or API token'
    )
    parser.add_argument(
        '--projects',
        nargs='+',
        help='Specific project keys to scan (space-separated). If not provided, scans all accessible projects'
    )
    parser.add_argument(
        '--output',
        '-o',
        help='Output file path (default: prints to stdout)'
    )
    
    args = parser.parse_args()
    
    # Initialize scanner
    scanner = BitbucketDockerScanner(args.url, args.username, args.password)
    
    # Scan repositories
    base_images = scanner.scan(args.projects)
    
    # Sort images for consistent output
    sorted_images = sorted(base_images)
    
    # Output results
    print("\n" + "="*60)
    print(f"FOUND {len(sorted_images)} UNIQUE BASE IMAGES")
    print("="*60)
    
    output_lines = [f"{img}" for img in sorted_images]
    output_text = "\n".join(output_lines)
    
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output_text + "\n")
        print(f"\nResults written to: {args.output}")
    else:
        print("\n" + output_text)


if __name__ == '__main__':
    main()
