#!/usr/bin/env python3
"""
Embedded Database Analyzer and Updater
Parses Lua embedded database files, collects statistics, and helps with compression analysis.
No Lua execution required - pure Python parsing.
"""

import sys
import json
import re
import argparse
import urllib.request
from pathlib import Path
from collections import defaultdict, Counter

# Set UTF-8 encoding for Windows console
if sys.platform == 'win32':
    import codecs
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout.buffer, 'strict')
    sys.stderr = codecs.getwriter('utf-8')(sys.stderr.buffer, 'strict')

class EmbeddedDatabaseAnalyzer:
    def __init__(self, db_folder):
        self.db_folder = Path(db_folder)
        self.databases = {}
        self.stats = {
            'total_entries': 0,
            'unique_sources': Counter(),
            'unique_reasons': Counter(),
            'unique_statics': Counter(),
            'unique_names': Counter(),
            'file_sizes': {},
        }

    def strip_reason_alias(self, reason):
        """
        Strip player alias from reason if present (only for MegaScaterbomb).
        Examples:
        "MegaScaterbomb (cheater) - casohi4685" → "MegaScaterbomb (cheater)"
        "Cheater (Rijin Alias) - valve employee" → "Cheater (Rijin Alias) - valve employee" (unchanged)
        """
        # Only strip aliases for MegaScaterbomb reasons (and only if it's a string)
        if isinstance(reason, str) and 'MegaScaterbomb' in reason and ' - ' in reason:
            # Strip everything after " - "
            return reason.split(' - ')[0]
        return reason

    def parse_lua_table(self, content):
        """
        Parse Lua table format without executing Lua.
        Handles both legacy verbose format and new normalized format.
        Extracts SteamID64 -> {Name, Reason, Source, Static, Flags, Timestamp} mappings.
        """
        entries = {}
        
        # Check if file uses normalized format
        if '_Metadata' in content and 'normalized' in content:
            return self.parse_normalized_format(content)
        
        # Legacy format: ["STEAMID"] = { Name = "...", Reason = "...", Source = "...", Static = "...", Flags = 0, Timestamp = 0 },
        # Also handle: ["STEAMID"] = { Name = "...", Reason = "...", Source = "...", Static = "...", Flags = 0 },
        pattern = r'\["(\d{17})"\]\s*=\s*{\s*Name\s*=\s*"([^"]*)"\s*,\s*Reason\s*=\s*"([^"]*)"\s*,\s*Source\s*=\s*"([^"]*)"\s*,\s*Static\s*=\s*"([^"]*)"\s*,\s*Flags\s*=\s*(\d+)(?:\s*,\s*Timestamp\s*=\s*(\d+))?\s*}'
        
        matches = re.finditer(pattern, content)
        if matches:
            for match in matches:
                steam_id = match.group(1)
                name = match.group(2)
                reason = match.group(3)
                source = match.group(4)
                static = match.group(5)
                flags = int(match.group(6))
                timestamp = int(match.group(7)) if match.group(7) else 0
                
                entries[steam_id] = {
                    'Name': name,
                    'Reason': reason,
                    'Source': source,
                    'Static': static,
                    'Flags': flags,
                    'Timestamp': timestamp
                }
        
        # Handle new global lookup format with mixed types (integers and strings)
        # Format: ["STEAMID"] = { flags, source_id_or_string, reason_id_or_string, static_id_or_string, name_id_or_string }
        if not entries and 'Format: Global lookup' in content:
            new_format_pattern = r'\["(\d{17})"\]\s*=\s*\{\s*([^}]+)\s*\}'
            new_format_matches = re.finditer(new_format_pattern, content)
            if new_format_matches:
                for match in new_format_matches:
                    steam_id = match.group(1)
                    values = match.group(2).split(',')
                    values = [v.strip() for v in values]
                    
                    # Parse values (handle both integers and strings)
                    flags = int(values[0]) if values[0].isdigit() else 0
                    source = int(values[1]) if values[1].isdigit() else values[1].strip('"')
                    reason = int(values[2]) if values[2].isdigit() else values[2].strip('"')
                    static = int(values[3]) if values[3].isdigit() else values[3].strip('"')
                    name = int(values[4]) if values[4].isdigit() else values[4].strip('"')
                    
                    entries[steam_id] = {
                        'Name': name,
                        'Reason': reason,
                        'Source': source,
                        'Static': static,
                        'Flags': flags,
                        'Timestamp': 0,
                        '_already_global_format': True  # Flag to indicate already converted
                    }
        
        # Handle tfcl_combined_lua format: ["STEAMID"] = { flags, source_id, reason_id, "name", timestamp }
        # Also parse the tfcl lookup tables if present
        tfcl_lookup = {}
        if 'Sources' in content and 'Reasons' in content:
            # Parse Sources
            sources_match = re.search(r'Sources\s*=\s*{([^}]+)}', content, re.DOTALL)
            if sources_match:
                for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', sources_match.group(1)):
                    tfcl_lookup[f'_source_id_{match.group(1)}'] = match.group(2)
            # Parse Reasons
            reasons_match = re.search(r'Reasons\s*=\s*{([^}]+)}', content, re.DOTALL)
            if reasons_match:
                for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', reasons_match.group(1)):
                    tfcl_lookup[f'_reason_id_{match.group(1)}'] = match.group(2)
        
        if not entries:
            tfcl_pattern = r'\["(\d{17})"\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*\}'
            tfcl_matches = re.finditer(tfcl_pattern, content)
            if tfcl_matches:
                # This format has IDs already, but name is a string
                # We need to convert the name string to an ID using the global lookup
                # But we don't have access to global lookup here, so we'll parse it
                # and handle conversion in the convert function
                for match in tfcl_matches:
                    steam_id = match.group(1)
                    flags = int(match.group(2))
                    source_id = int(match.group(3))
                    reason_id = int(match.group(4))
                    name = match.group(5)
                    timestamp = int(match.group(6))
                    
                    entries[steam_id] = {
                        'Name': name,
                        'Reason': f'_reason_id_{reason_id}',  # Placeholder
                        'Source': f'_source_id_{source_id}',    # Placeholder
                        'Static': f'_static_id_0',             # Placeholder
                        'Flags': flags,
                        'Timestamp': timestamp,
                        '_tfcl_format': True,  # Flag to indicate special format
                        '_source_id': source_id,
                        '_reason_id': reason_id
                    }
        
        return entries

    def parse_normalized_format(self, content):
        """
        Parse normalized Lua table format.
        Format: _Metadata, Sources, Reasons, Statics, Names, Data arrays
        Data entries: ["STEAMID"] = { Flags, SourceID, ReasonID, StaticID, NameID, Timestamp }
        """
        entries = {}
        
        # Extract lookup tables
        sources = {}
        reasons = {}
        statics = {}
        names = {}
        
        # Parse Sources array - handle multiline with non-greedy matching
        source_pattern = r'Sources\s*=\s*\{([^}]+)\}'
        source_match = re.search(source_pattern, content, re.DOTALL | re.IGNORECASE)
        if source_match:
            source_content = source_match.group(1)
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]*)"', source_content):
                idx = int(match.group(1))
                val = match.group(2)
                sources[idx] = val
        
        # Parse Reasons array
        reason_pattern = r'Reasons\s*=\s*\{([^}]+)\}'
        reason_match = re.search(reason_pattern, content, re.DOTALL | re.IGNORECASE)
        if reason_match:
            reason_content = reason_match.group(1)
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]*)"', reason_content):
                idx = int(match.group(1))
                val = match.group(2)
                reasons[idx] = val
        
        # Parse Statics array
        static_pattern = r'Statics\s*=\s*\{([^}]+)\}'
        static_match = re.search(static_pattern, content, re.DOTALL | re.IGNORECASE)
        if static_match:
            static_content = static_match.group(1)
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]*)"', static_content):
                idx = int(match.group(1))
                val = match.group(2)
                statics[idx] = val
        
        # Parse Names array
        name_pattern = r'Names\s*=\s*\{([^}]+)\}'
        name_match = re.search(name_pattern, content, re.DOTALL | re.IGNORECASE)
        if name_match:
            name_content = name_match.group(1)
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]*)"', name_content):
                idx = int(match.group(1))
                val = match.group(2)
                names[idx] = val
        
        # Parse Data array - need to handle nested braces
        # Find the Data section and extract it properly
        data_start = content.find('Data = {')
        if data_start != -1:
            # Find the matching closing brace for Data
            brace_count = 0
            data_end = data_start + len('Data = {') - 1
            for i, char in enumerate(content[data_start:]):
                if char == '{':
                    brace_count += 1
                elif char == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        data_end = data_start + i
                        break
            
            data_content = content[data_start + len('Data = {'):data_end]
            
            # Pattern: ["STEAMID"] = { Flags, SourceID, ReasonID, StaticID, NameID, Timestamp }
            entry_pattern = r'\["(\d{17})"\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}'
            
            for match in re.finditer(entry_pattern, data_content):
                steam_id = match.group(1)
                flags = int(match.group(2))
                source_id = int(match.group(3))
                reason_id = int(match.group(4))
                static_id = int(match.group(5))
                name_id = int(match.group(6))
                timestamp = int(match.group(7))
                
                # Decode IDs to strings
                source = sources.get(source_id, "Unknown")
                reason = reasons.get(reason_id, "Unknown")
                static = statics.get(static_id, False)
                name = names.get(name_id, "Unknown")
                
                entries[steam_id] = {
                    'Name': name,
                    'Reason': reason,
                    'Source': source,
                    'Static': static,
                    'Flags': flags,
                    'Timestamp': timestamp
                }
        
        return entries

    def load_database(self, filepath):
        """Load and parse a single embedded database file."""
        # Convert string to Path if needed
        if isinstance(filepath, str):
            filepath = Path(filepath)
        
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        entries = self.parse_lua_table(content)
        filename = filepath.name
        self.databases[filename] = entries
        
        # Collect statistics
        for steam_id, entry in entries.items():
            self.stats['total_entries'] += 1
            self.stats['unique_sources'][entry['Source']] += 1
            self.stats['unique_reasons'][entry['Reason']] += 1
            self.stats['unique_statics'][entry['Static']] += 1
            
            # Only count placeholder names for compression statistics
            name = entry['Name']
            is_placeholder = (isinstance(name, str) and (
                name == "Unknown" or 
                name == "nn" or 
                name == "null" or 
                name == "N/A" or 
                len(name) < 3 or
                name.isspace()
            ))
            if is_placeholder:
                self.stats['unique_names'][name] += 1
        
        self.stats['file_sizes'][filename] = filepath.stat().st_size
        
        return entries

    def load_all_databases(self):
        """Load all embedded database files from the folder."""
        lua_files = list(self.db_folder.glob('*.lua'))
        
        print(f"Found {len(lua_files)} embedded database files")
        
        for filepath in sorted(lua_files):
            print(f"Loading: {filepath.name}...")
            try:
                self.load_database(filepath)
            except Exception as e:
                print(f"  Error loading {filepath.name}: {e}")

    def print_statistics(self):
        """Print comprehensive statistics about the embedded databases."""
        print("\n" + "="*80)
        print("EMBEDDED DATABASE STATISTICS")
        print("="*80)
        
        print(f"\nTotal Entries: {self.stats['total_entries']:,}")
        print(f"Total Files: {len(self.databases)}")
        
        print("\n" + "-"*80)
        print("FILE SIZES")
        print("-"*80)
        total_size = sum(self.stats['file_sizes'].values())
        for filename, size in sorted(self.stats['file_sizes'].items(), key=lambda x: x[1], reverse=True):
            print(f"  {filename:40s} {size:>10,} bytes ({size/1024/1024:.2f} MB)")
        print(f"  {'TOTAL':40s} {total_size:>10,} bytes ({total_size/1024/1024:.2f} MB)")
        
        print("\n" + "-"*80)
        print("UNIQUE SOURCES (with occurrence counts)")
        print("-"*80)
        for source, count in self.stats['unique_sources'].most_common():
            print(f"  {source:50s} {count:>6,} ({count/self.stats['total_entries']*100:.2f}%)")
        
        print("\n" + "-"*80)
        print("UNIQUE REASONS (with occurrence counts)")
        print("-"*80)
        for reason, count in self.stats['unique_reasons'].most_common():
            print(f"  {reason:60s} {count:>6,} ({count/self.stats['total_entries']*100:.2f}%)")
        
        print("\n" + "-"*80)
        print("UNIQUE STATICS (with occurrence counts)")
        print("-"*80)
        for static, count in self.stats['unique_statics'].most_common():
            print(f"  {static:30s} {count:>6,} ({count/self.stats['total_entries']*100:.2f}%)")
        
        print("\n" + "-"*80)
        print("UNIQUE PLACEHOLDER NAMES (only these are compressed)")
        print("-"*80)
        for name, count in self.stats['unique_names'].most_common(20):
            print(f"  {name:40s} {count:>6,} ({count/self.stats['total_entries']*100:.2f}%)")
        
        print("\n" + "-"*80)
        print("COMPRESSION ANALYSIS")
        print("-"*80)
        
        # Calculate compression potential
        unique_sources = len(self.stats['unique_sources'])
        unique_reasons = len(self.stats['unique_reasons'])
        unique_statics = len(self.stats['unique_statics'])
        unique_names = len(self.stats['unique_names'])
        
        print(f"Unique Sources: {unique_sources}")
        print(f"Unique Reasons: {unique_reasons}")
        print(f"Unique Statics: {unique_statics}")
        print(f"Unique Names: {unique_names}")
        
        # Estimate size reduction if normalized
        # Current: Each entry repeats full strings
        # Normalized: Each entry uses integer IDs, strings stored once in lookup tables
        
        avg_source_len = sum(len(s) for s in self.stats['unique_sources'].keys()) / unique_sources
        avg_reason_len = sum(len(r) for r in self.stats['unique_reasons'].keys()) / unique_reasons
        avg_static_len = sum(len(s) for s in self.stats['unique_statics'].keys()) / unique_statics
        avg_name_len = sum(len(n) for n in self.stats['unique_names'].keys()) / unique_names
        
        current_string_bytes = (
            self.stats['total_entries'] * (avg_source_len + avg_reason_len + avg_static_len + avg_name_len)
        )
        
        normalized_string_bytes = (
            (unique_sources * avg_source_len) +
            (unique_reasons * avg_reason_len) +
            (unique_statics * avg_static_len) +
            (unique_names * avg_name_len)
        )
        
        savings = current_string_bytes - normalized_string_bytes
        savings_percent = (savings / current_string_bytes) * 100
        
        print(f"\nEstimated String Data (Current): {current_string_bytes:,.0f} bytes")
        print(f"Estimated String Data (Normalized): {normalized_string_bytes:,.0f} bytes")
        print(f"Potential Savings: {savings:,.0f} bytes ({savings_percent:.1f}%)")

    def export_statistics(self, output_file):
        """Export statistics to JSON file."""
        export_data = {
            'total_entries': self.stats['total_entries'],
            'file_sizes': {k: v for k, v in self.stats['file_sizes'].items()},
            'unique_sources': dict(self.stats['unique_sources']),
            'unique_reasons': dict(self.stats['unique_reasons']),
            'unique_statics': dict(self.stats['unique_statics']),
            'unique_names': dict(self.stats['unique_names']),
        }
        
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(export_data, f, indent=2)
        
        print(f"\nStatistics exported to: {output_file}")

    def update_source(self, old_source, new_source):
        """
        Update all occurrences of a source string across all embedded databases.
        This modifies the actual Lua files.
        """
        updated_files = 0
        updated_entries = 0
        
        for filepath in self.db_folder.glob('*.lua'):
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Replace Source = "old_source" with Source = "new_source"
            pattern = rf'(Source\s*=\s*)"{re.escape(old_source)}"'
            replacement = rf'\1"{new_source}"'
            
            new_content = re.sub(pattern, replacement, content)
            
            if new_content != content:
                # Count how many entries were updated
                matches = re.findall(pattern, content)
                updated_entries += len(matches)
                
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                
                updated_files += 1
                print(f"  Updated: {filepath.name} ({len(matches)} entries)")
        
        print(f"\nUpdated {updated_entries} entries in {updated_files} files")
        print(f"Changed '{old_source}' -> '{new_source}'")

    def generate_normalized_lua(self, output_file):
        """
        Generate a normalized version of all embedded databases combined.
        Uses integer IDs for compression.
        Version 3 format: { Flags, SourceID, StaticID, Name, Reason, Timestamp }
        """
        # Collect all unique strings
        all_sources = Counter()
        all_reasons = Counter()
        all_statics = Counter()
        all_names_occurrences = Counter()  # Track name occurrences for compression
        
        # First pass: count all occurrences
        for filename, entries in self.databases.items():
            for steam_id, entry in entries.items():
                all_sources[entry['Source']] += 1
                all_reasons[entry['Reason']] += 1
                all_statics[entry['Static']] += 1
                all_names_occurrences[entry['Name']] += 1
        
        # Second pass: collect only names that appear 5+ times
        all_names = Counter()
        for name, count in all_names_occurrences.items():
            if count >= 5:
                all_names[name] = count
        
        # Build lookup tables
        sources = {name: i+1 for i, name in enumerate(sorted(all_sources.keys()))}
        reasons = {name: i+1 for i, name in enumerate(sorted(all_reasons.keys()))}
        statics = {name: i+1 for i, name in enumerate(sorted(all_statics.keys()))}
        names = {name: i+1 for i, name in enumerate(sorted(all_names.keys()))}
        
        # Build reverse maps
        source_array = {i: name for name, i in sources.items()}
        reason_array = {i: name for name, i in reasons.items()}
        static_array = {i: name for name, i in statics.items()}
        name_array = {i: name for name, i in names.items()}
        
        # Build normalized data
        normalized_data = {}
        for filename, entries in self.databases.items():
            for steam_id, entry in entries.items():
                flags = entry['Flags']
                source_id = sources.get(entry['Source'], 0)
                static_id = statics.get(entry['Static'], 0)
                
                # Name: ID if appears 5+ times, else raw string
                name_occurrences = all_names_occurrences[entry['Name']]
                if name_occurrences >= 5:
                    name_value = names.get(entry['Name'], entry['Name'])
                else:
                    name_value = entry['Name']
                
                # Reason: ID if common, else raw string (keep raw for unique reasons)
                if all_reasons[entry['Reason']] >= 3 and len(entry['Reason']) <= 40:
                    reason_value = reasons.get(entry['Reason'], entry['Reason'])
                else:
                    reason_value = entry['Reason']
                
                timestamp = entry['Timestamp']
                
                # Build entry: { Flags, SourceID, StaticID, Name, Reason, Timestamp }
                entry_array = [flags, source_id, static_id, name_value, reason_value, timestamp]
                normalized_data[steam_id] = entry_array
        
        # Build Lua table
        lua_content = "-- Combined Normalized Embedded Database\n"
        lua_content += f"-- Total Entries: {len(normalized_data)}\n"
        lua_content += "-- Version: 3\n"
        lua_content += "-- Format: { Flags, SourceID, StaticID, Name, Reason, Timestamp }\n"
        lua_content += "-- Name/Reason can be integer ID (compressed) or raw string (unique)\n\n"
        
        lua_content += "return {\n"
        lua_content += "    _Metadata = {\n"
        lua_content += "        Version = 3,\n"
        lua_content += "        Format = \"normalized\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Sources = {\n"
        for i in sorted(source_array.keys()):
            lua_content += f"        [{i}] = \"{source_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Reasons = {\n"
        for i in sorted(reason_array.keys()):
            lua_content += f"        [{i}] = \"{reason_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Statics = {\n"
        for i in sorted(static_array.keys()):
            lua_content += f"        [{i}] = \"{static_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Names = {\n"
        for i in sorted(name_array.keys()):
            lua_content += f"        [{i}] = \"{name_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Data = {\n"
        for steam_id in sorted(normalized_data.keys()):
            entry = normalized_data[steam_id]
            # Format each value appropriately
            formatted_entry = []
            for val in entry:
                if isinstance(val, str):
                    formatted_entry.append(f'"{val}"')
                else:
                    formatted_entry.append(str(val))
            lua_content += f'        ["{steam_id}"] = {{ {", ".join(formatted_entry)} }},\n'
        lua_content += "    },\n"
        lua_content += "}\n"
        
        # Write to file
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(lua_content)
        
        print(f"Generated normalized database: {output_file}")
        print(f"  Sources: {len(sources)}, Reasons: {len(reasons)}, Statics: {len(statics)}, Names: {len(names)}")

    def generate_global_lookup_tables(self, output_file, include_runtime=False):
        """
        Generate global lookup tables from all embedded databases.
        Contains Sources, Reasons, Statics, and Names that appear 4+ times across all databases.
        If include_runtime=True, also fetches and includes runtime sources.
        """
        # Collect all unique strings across all databases
        all_sources = Counter()
        all_reasons = Counter()
        all_statics = Counter()
        all_names_occurrences = Counter()
        
        # First pass: count all occurrences from embedded databases
        for filename, entries in self.databases.items():
            for steam_id, entry in entries.items():
                all_sources[entry['Source']] += 1
                # Strip alias from reason before counting
                reason_clean = self.strip_reason_alias(entry['Reason'])
                all_reasons[reason_clean] += 1
                all_statics[entry['Static']] += 1
                all_names_occurrences[entry['Name']] += 1
        
        # Include runtime sources if requested
        if include_runtime:
            print("Fetching runtime sources for comprehensive global lookup...")
            runtime_data = self.fetch_runtime_sources()
            for steam_id, entry in runtime_data.items():
                all_sources[entry['Source']] += 1
                # Strip alias from reason before counting
                reason_clean = self.strip_reason_alias(entry['Reason'])
                all_reasons[reason_clean] += 1
                all_statics[entry['Static']] += 1
                all_names_occurrences[entry['Name']] += 1
        
        # Second pass: collect only items that appear 4+ times (lower threshold for global lookup)
        all_names = Counter()
        for name, count in all_names_occurrences.items():
            if count >= 4:
                all_names[name] = count
        
        # Build lookup tables
        sources = {name: i+1 for i, name in enumerate(sorted(all_sources.keys()))}
        reasons = {name: i+1 for i, name in enumerate(sorted(all_reasons.keys()))}
        statics = {name: i+1 for i, name in enumerate(sorted(all_statics.keys()))}
        names = {name: i+1 for i, name in enumerate(sorted(all_names.keys()))}
        
        # Build reverse maps
        source_array = {i: name for name, i in sources.items()}
        reason_array = {i: name for name, i in reasons.items()}
        static_array = {i: name for name, i in statics.items()}
        name_array = {i: name for name, i in names.items()}
        
        # Build Lua table
        lua_content = "-- Global Lookup Tables for Embedded Databases\n"
        lua_content += "-- Contains Sources, Reasons, Statics, and Names that appear 5+ times across all databases\n"
        lua_content += "-- All embedded databases reference these IDs instead of duplicating strings\n"
        lua_content += f"-- Generated from {len(self.databases)} embedded database files\n\n"
        
        lua_content += "return {\n"
        
        lua_content += "    Sources = {\n"
        for i in sorted(source_array.keys()):
            lua_content += f"        [{i}] = \"{source_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Reasons = {\n"
        for i in sorted(reason_array.keys()):
            lua_content += f"        [{i}] = \"{reason_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Statics = {\n"
        for i in sorted(static_array.keys()):
            lua_content += f"        [{i}] = \"{static_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "    Names = {\n"
        for i in sorted(name_array.keys()):
            lua_content += f"        [{i}] = \"{name_array[i]}\",\n"
        lua_content += "    },\n"
        
        lua_content += "}\n"
        
        # Write to file
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(lua_content)
        
        print(f"Generated global lookup tables: {output_file}")
        print(f"  Sources: {len(sources)}, Reasons: {len(reasons)}, Statics: {len(statics)}, Names: {len(names)}")
        
        # Show statistics about excluded items
        print(f"\nReasons appearing less than 4 times (excluded from global lookup):")
        excluded_reasons = [r for r, c in all_reasons.items() if c < 4]
        print(f"  Total excluded reasons: {len(excluded_reasons)}")
        if excluded_reasons:
            print(f"  Sample of first 20 excluded reasons:")
            for i, reason in enumerate(sorted(excluded_reasons, key=lambda x: all_reasons[x], reverse=True)[:20]):
                print(f"    {reason} (count: {all_reasons[reason]})")
        
        print(f"\nNames appearing less than 4 times (excluded from global lookup):")
        excluded_names = [n for n, c in all_names_occurrences.items() if c < 4]
        print(f"  Total excluded names: {len(excluded_names)}")

    def fetch_runtime_sources(self):
        """
        Fetch runtime sources (Masterbase, TF2BD Biglist, TF2BD Trusted, qfoxb live, joekiller live)
        and return them as a dictionary compatible with the embedded database format.
        """
        runtime_data = {}
        
        # Runtime source definitions (from Sources.lua)
        runtime_sources = [
            {
                "name": "Masterbase Broadcasts",
                "url": "https://megaanticheat.com/broadcasts",
                "parser": "broadcasts",
                "source_label": "Masterbase Broadcasts",
                "static_id": "masterbase",
                "default_reason": "Masterbase Broadcast Conviction",
            },
            {
                "name": "TF2BD Community Biglist",
                "url": "https://gist.githubusercontent.com/wgetJane/0bc01bd46d7695362253c5a2fa49f2e9/raw/playerlist.biglist.json",
                "parser": "tf2db",
                "source_label": "TF2BD Community Biglist",
                "static_id": "cc_biglist",
                "default_reason": "Bot (TF2BD Community Biglist)",
            },
            {
                "name": "TF2BD Community Trusted",
                "url": "https://trusted.roto.lol/v1/steamids",
                "parser": "tf2db",
                "source_label": "TF2BD Community Trusted",
                "static_id": "cc_trusted",
                "default_reason": "Cheater (TF2BD Trusted)",
            },
            {
                "name": "qfoxb Player List (live)",
                "url": "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
                "parser": "tf2db",
                "source_label": "qfoxb Cheater List",
                "static_id": "qfoxb",
                "default_reason": "Cheater (qfoxb)",
            },
            {
                "name": "joekiller Player List (live)",
                "url": "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
                "parser": "tf2db",
                "source_label": "joekiller Cheater List",
                "static_id": "joekiller",
                "default_reason": "Cheater (joekiller)",
            },
        ]
        
        for source in runtime_sources:
            try:
                print(f"Fetching {source['name']}...")
                req = urllib.request.Request(
                    source['url'],
                    headers={'User-Agent': 'Mozilla/5.0'}
                )
                with urllib.request.urlopen(req, timeout=30) as response:
                    content = response.read().decode('utf-8')
                
                # Parse based on parser type
                if source['parser'] == 'broadcasts':
                    # Parse Masterbase broadcasts format
                    entries = self.parse_broadcasts(content, source)
                elif source['parser'] == 'tf2db':
                    # Parse TF2BD JSON format
                    entries = self.parse_tf2db_json(content, source)
                else:
                    print(f"  Unknown parser: {source['parser']}")
                    continue
                
                # Add to runtime_data
                for steam_id, entry in entries.items():
                    runtime_data[steam_id] = entry
                
                print(f"  Fetched {len(entries)} entries from {source['name']}")
            except Exception as e:
                print(f"  Error fetching {source['name']}: {e}")
        
        return runtime_data
    
    def parse_broadcasts(self, content, source):
        """Parse Masterbase broadcasts format."""
        entries = {}
        try:
            data = json.loads(content)
            if isinstance(data, dict) and 'broadcasts' in data:
                for broadcast in data['broadcasts']:
                    if 'steamid64' in broadcast:
                        steam_id = str(broadcast['steamid64'])
                        entries[steam_id] = {
                            'Name': broadcast.get('name', 'Unknown'),
                            'Reason': source['default_reason'],
                            'Source': source['source_label'],
                            'Static': source['static_id'],
                            'Flags': 0,
                        }
        except Exception as e:
            print(f"  Error parsing broadcasts: {e}")
        return entries
    
    def parse_tf2db_json(self, content, source):
        """Parse TF2BD JSON format."""
        entries = {}
        try:
            data = json.loads(content)
            # Handle both array format and object format with 'players' key
            players = data if isinstance(data, list) else data.get('players', [])
            for player in players:
                # Handle both [U:1:XXXXXX] and steamid64 formats
                steamid = player.get('steamid')
                if steamid:
                    # Convert [U:1:XXXXXX] to SteamID64 if needed
                    if isinstance(steamid, str) and re.match(r'^\[U:1:\d+\]$', steamid):
                        # Convert SteamID2 to SteamID64
                        match = re.match(r'\[U:1:(\d+)\]', steamid)
                        if match:
                            steamid64 = 76561197960265728 + int(match.group(1))
                            steam_id = str(steamid64)
                    else:
                        steam_id = str(steamid)
                    
                    entries[steam_id] = {
                        'Name': player.get('name', 'Unknown'),
                        'Reason': source['default_reason'],
                        'Source': source['source_label'],
                        'Static': source['static_id'],
                        'Flags': 0,
                    }
        except Exception as e:
            print(f"  Error parsing TF2BD JSON: {e}")
            import traceback
            traceback.print_exc()
        return entries

    def convert_to_global_lookup_format(self, global_lookup_file):
        """
        Convert all embedded databases to use global lookup format.
        Removes individual Sources/Reasons/Statics/Names tables from each file.
        """
        # Load global lookup tables
        try:
            with open(global_lookup_file, 'r', encoding='utf-8') as f:
                content = f.read()
            # Parse the global lookup tables
            global_sources = {}
            global_reasons = {}
            global_statics = {}
            global_names = {}
            
            # Simple regex parsing
            import re
            sources_pattern = r'\[(\d+)\]\s*=\s*"([^"]*)"'
            
            # Parse Sources
            sources_match = re.search(r'Sources\s*=\s*{([^}]+)}', content, re.DOTALL)
            if sources_match:
                for match in re.finditer(sources_pattern, sources_match.group(1)):
                    global_sources[int(match.group(1))] = match.group(2)
            
            # Parse Reasons
            reasons_match = re.search(r'Reasons\s*=\s*{([^}]+)}', content, re.DOTALL)
            if reasons_match:
                for match in re.finditer(sources_pattern, reasons_match.group(1)):
                    global_reasons[int(match.group(1))] = match.group(2)
            
            # Parse Statics
            statics_match = re.search(r'Statics\s*=\s*{([^}]+)}', content, re.DOTALL)
            if statics_match:
                for match in re.finditer(sources_pattern, statics_match.group(1)):
                    global_statics[int(match.group(1))] = match.group(2)
            
            # Parse Names (it's the last section, so capture everything after "Names = {")
            names_match = re.search(r'Names\s*=\s*{(.+)', content, re.DOTALL)
            if names_match:
                # Remove the closing brace at the end
                names_content = names_match.group(1).rstrip().rstrip('}')
                for match in re.finditer(sources_pattern, names_content):
                    global_names[int(match.group(1))] = match.group(2)
            
            print(f"Loaded global lookup tables: {len(global_sources)} sources, {len(global_reasons)} reasons, {len(global_statics)} statics, {len(global_names)} names")
        except Exception as e:
            print(f"Error loading global lookup tables: {e}")
            return
        
        # Build reverse maps
        source_to_id = {v: k for k, v in global_sources.items()}
        reason_to_id = {v: k for k, v in global_reasons.items()}
        static_to_id = {v: k for k, v in global_statics.items()}
        name_to_id = {v: k for k, v in global_names.items()}
        
        # Convert each embedded database
        for filepath in self.db_folder.glob('*.lua'):
            if filepath.name == 'global_lookup_tables.lua':
                continue
            
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                # Check if already in global format (check if entries use integer IDs)
                # Skip only if entries are already integers, not strings
                if 'Data = {' in content and 'Format: Global lookup' in content:
                    # Check if entries use strings (bad) or integers (good)
                    # If any entry has a quoted string in the data array, it needs conversion
                    string_match = re.search(r'\["\d+"\]\s*=\s*\{[^}]*"[^}]*\}', content)
                    if not string_match:
                        print(f"Skipping {filepath.name}: already in global format with integer IDs")
                        continue
                
                # Parse the current file
                parsed = self.parse_lua_table(content)
                if not parsed:
                    print(f"Skipping {filepath.name}: failed to parse")
                    continue
                
                # Skip if already in new global format with inlined strings
                if any(entry.get('_already_global_format') for entry in parsed.values()):
                    print(f"Skipping {filepath.name}: already in new global format with inlined strings")
                    continue
                
                # Build new Data array using global lookup IDs, inlining unique strings
                new_data = {}
                
                for steam_id, entry in parsed.items():
                    flags = entry.get('Flags', 0)
                    
                    # Handle tfcl format (has _tfcl_format flag)
                    if entry.get('_tfcl_format'):
                        # tfcl format: flags, source_id, reason_id, name_string, timestamp
                        source_id = entry['_source_id']
                        reason_id = entry['_reason_id']
                        name = entry['Name']
                        
                        # Strip alias from reason (tfcl reasons have aliases)
                        # Get the actual reason string from the ID map or use placeholder
                        reason_str = entry['Reason']  # This is a placeholder like '_reason_id_X'
                        # For tfcl, we need to look up the reason from the ID
                        # Since we don't have the lookup here, we'll inline the reason string directly
                        # The tfcl format already has the reason as an ID, so we need to convert it
                        # For now, just inline the name as string
                        static_id = 0  # tfcl doesn't have static
                        
                        # Build normalized entry: [Flags, SourceID, ReasonID, StaticID, NameString]
                        new_data[steam_id] = [flags, source_id, reason_id, static_id, name]
                    else:
                        # Standard format
                        source = entry['Source']
                        reason = entry['Reason']
                        static = entry['Static']
                        name = entry['Name']
                        
                        # Strip alias from reason for megascat/rijin
                        reason_clean = self.strip_reason_alias(reason)
                        
                        # Get IDs from global lookup (use 0 if not found)
                        source_id = source_to_id.get(source, 0)
                        reason_id = reason_to_id.get(reason_clean, 0)
                        static_id = static_to_id.get(static, 0)
                        name_id = name_to_id.get(name, 0)
                        
                        # Build normalized entry: inline strings not in global lookup
                        new_data[steam_id] = [
                            flags,
                            source_id if source_id != 0 else source,
                            reason_id if reason_id != 0 else reason,
                            static_id if static_id != 0 else static,
                            name_id if name_id != 0 else name
                        ]
                
                # Build new Lua content (no local lookup tables - inline strings)
                lua_content = f"-- Embedded Database: {filepath.stem}\n"
                lua_content += f"-- Format: Global lookup IDs (references global_lookup_tables.lua)\n"
                lua_content += f"-- Total Entries: {len(new_data)}\n\n"
                lua_content += "return {\n"
                lua_content += "    Data = {\n"
                
                for steam_id in sorted(new_data.keys()):
                    entry = new_data[steam_id]
                    # Format values: integers as-is, strings as quoted
                    formatted_values = []
                    for v in entry:
                        if isinstance(v, int):
                            formatted_values.append(str(v))
                        else:
                            formatted_values.append(f'"{v}"')
                    lua_content += f'        ["{steam_id}"] = {{ {", ".join(formatted_values)} }},\n'
                
                lua_content += "    },\n"
                lua_content += "}\n"
                
                # Write back
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(lua_content)
                
                print(f"Converted {filepath.name} to global lookup format")
            except Exception as e:
                print(f"Error converting {filepath.name}: {e}")


def main():
    parser = argparse.ArgumentParser(description='Analyze and update embedded databases')
    parser.add_argument('--folder', default='Cheater_Detection/Database/Static_Embeded_Databases',
                        help='Path to embedded databases folder')
    parser.add_argument('--stats', action='store_true',
                        help='Print statistics')
    parser.add_argument('--export', metavar='FILE',
                        help='Export statistics to JSON file')
    parser.add_argument('--update-source', nargs=2, metavar=('OLD', 'NEW'),
                        help='Update source string (e.g., "Old Name" "New Name")')
    parser.add_argument('--generate-normalized', metavar='FILE',
                        help='Generate normalized combined database')
    
    parser.add_argument('--generate-global', metavar='FILE',
                        help='Generate global lookup tables from all embedded databases')
    parser.add_argument('--include-runtime', action='store_true',
                        help='Include runtime sources (Masterbase, TF2BD Biglist, TF2BD Trusted, qfoxb live, joekiller live) in global lookup tables')
    parser.add_argument('--convert-global', metavar='FILE',
                        help='Convert embedded databases to use global lookup format (requires global lookup file)')
    args = parser.parse_args()
    
    analyzer = EmbeddedDatabaseAnalyzer(args.folder)
    analyzer.load_all_databases()
    
    if args.stats:
        analyzer.print_statistics()
    
    if args.export:
        analyzer.export_statistics(args.export)
    
    if args.update_source:
        analyzer.update_source_string(args.update_source[0], args.update_source[1])
    
    if args.generate_normalized:
        analyzer.generate_normalized_lua(args.generate_normalized)
    
    if args.generate_global:
        analyzer.generate_global_lookup_tables(args.generate_global, args.include_runtime)
    
    if args.convert_global:
        analyzer.convert_to_global_lookup_format(args.convert_global)
    
    # If no specific action requested, just print stats
    if not any([args.stats, args.export, args.update_source, args.generate_normalized, args.generate_global, args.convert_global]):
        analyzer.print_statistics()


if __name__ == '__main__':
    main()
