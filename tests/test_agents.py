"""
Basic tests for the Deep Research Agent.

These tests are designed to run in CI without requiring actual API keys.
They verify that modules can be imported and basic structures are correct.
"""

import pytest


class TestImports:
    """Test that all modules can be imported successfully."""

    def test_import_research_agent(self):
        """Test importing the research agent module."""
        from deep_research_from_scratch import research_agent
        assert research_agent is not None

    def test_import_multi_agent_supervisor(self):
        """Test importing the multi-agent supervisor module."""
        from deep_research_from_scratch import multi_agent_supervisor
        assert multi_agent_supervisor is not None

    def test_import_utils(self):
        """Test importing the utils module."""
        from deep_research_from_scratch import utils
        assert utils is not None

    def test_import_prompts(self):
        """Test importing the prompts module."""
        from deep_research_from_scratch import prompts
        assert prompts is not None

    def test_import_states(self):
        """Test importing state modules."""
        from deep_research_from_scratch import state_research
        from deep_research_from_scratch import state_scope
        from deep_research_from_scratch import state_multi_agent_supervisor
        
        assert state_research is not None
        assert state_scope is not None
        assert state_multi_agent_supervisor is not None


class TestAgentGraphs:
    """Test that agent graphs are properly compiled."""

    def test_researcher_agent_exists(self):
        """Test that researcher agent graph is compiled."""
        from deep_research_from_scratch.research_agent import researcher_agent
        
        assert researcher_agent is not None
        assert hasattr(researcher_agent, 'invoke')
        assert hasattr(researcher_agent, 'ainvoke')

    def test_supervisor_agent_exists(self):
        """Test that supervisor agent graph is compiled."""
        from deep_research_from_scratch.multi_agent_supervisor import supervisor_agent
        
        assert supervisor_agent is not None
        assert hasattr(supervisor_agent, 'invoke')
        assert hasattr(supervisor_agent, 'ainvoke')

    def test_scope_research_exists(self):
        """Test that scope research agent is compiled."""
        from deep_research_from_scratch.research_agent_scope import scope_research
        
        assert scope_research is not None
        assert hasattr(scope_research, 'invoke')
        assert hasattr(scope_research, 'ainvoke')

    def test_full_agent_exists(self):
        """Test that full research agent workflow is compiled."""
        from deep_research_from_scratch.research_agent_full import agent
        
        assert agent is not None
        assert hasattr(agent, 'invoke')
        assert hasattr(agent, 'ainvoke')


class TestTools:
    """Test that tools are properly defined."""

    def test_tavily_search_tool(self):
        """Test that tavily search tool is defined."""
        from deep_research_from_scratch.utils import tavily_search
        
        assert tavily_search is not None
        assert hasattr(tavily_search, 'invoke')
        assert hasattr(tavily_search, 'name')

    def test_think_tool(self):
        """Test that think tool is defined."""
        from deep_research_from_scratch.utils import think_tool
        
        assert think_tool is not None
        assert hasattr(think_tool, 'invoke')
        assert hasattr(think_tool, 'name')

    def test_think_tool_execution(self):
        """Test that think tool can be invoked."""
        from deep_research_from_scratch.utils import think_tool
        
        result = think_tool.invoke({"reflection": "Test reflection"})
        assert "Reflection recorded" in result
        assert "Test reflection" in result


class TestUtilityFunctions:
    """Test utility functions."""

    def test_get_today_str(self):
        """Test that get_today_str returns a valid date string."""
        from deep_research_from_scratch.utils import get_today_str
        
        result = get_today_str()
        assert isinstance(result, str)
        assert len(result) > 0
        # Should contain year
        assert "202" in result or "203" in result

    def test_get_current_dir(self):
        """Test that get_current_dir returns a valid path."""
        from deep_research_from_scratch.utils import get_current_dir
        from pathlib import Path
        
        result = get_current_dir()
        assert isinstance(result, Path)


class TestPrompts:
    """Test that prompts are properly defined."""

    def test_research_agent_prompt_exists(self):
        """Test that research agent prompt is defined."""
        from deep_research_from_scratch.prompts import research_agent_prompt
        
        assert research_agent_prompt is not None
        assert isinstance(research_agent_prompt, str)
        assert len(research_agent_prompt) > 0

    def test_lead_researcher_prompt_exists(self):
        """Test that lead researcher prompt is defined."""
        from deep_research_from_scratch.prompts import lead_researcher_prompt
        
        assert lead_researcher_prompt is not None
        assert isinstance(lead_researcher_prompt, str)
        assert len(lead_researcher_prompt) > 0


class TestStateSchemas:
    """Test that state schemas are properly defined."""

    def test_researcher_state_fields(self):
        """Test ResearcherState has required fields."""
        from deep_research_from_scratch.state_research import ResearcherState
        
        # Check that it's a TypedDict or similar
        assert hasattr(ResearcherState, '__annotations__')
        annotations = ResearcherState.__annotations__
        
        assert 'researcher_messages' in annotations

    def test_supervisor_state_fields(self):
        """Test SupervisorState has required fields."""
        from deep_research_from_scratch.state_multi_agent_supervisor import SupervisorState
        
        assert hasattr(SupervisorState, '__annotations__')
        annotations = SupervisorState.__annotations__
        
        assert 'supervisor_messages' in annotations


# Skip integration tests that require API keys
@pytest.mark.skip(reason="Requires API keys - run manually for integration testing")
class TestIntegration:
    """Integration tests that require actual API connections."""

    @pytest.mark.asyncio
    async def test_research_agent_basic_query(self):
        """Test research agent with a simple query."""
        from deep_research_from_scratch.research_agent import researcher_agent
        from langchain_core.messages import HumanMessage
        
        result = await researcher_agent.ainvoke({
            "researcher_messages": [
                HumanMessage(content="What is the capital of France?")
            ]
        })
        
        assert "compressed_research" in result
        assert len(result["compressed_research"]) > 0


